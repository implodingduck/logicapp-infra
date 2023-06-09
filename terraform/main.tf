terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.53.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "1.5.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

locals {
  la_name = "la${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  gh_repo = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "environment" = var.environment
    "repo"       = local.gh_repo
  }
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-EUS"
  resource_group_name = "DefaultResourceGroup-EUS"
} 
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${var.environment}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-${local.gh_repo}-${var.environment}-${random_string.unique.result}-${local.loc_for_naming}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.4.0.0/24"]

  tags = local.tags
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-privateendpoints-${local.loc_for_naming}"
  resource_group_name  = azurerm_virtual_network.default.resource_group_name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.4.0.0/26"]

  private_endpoint_network_policies_enabled = true

}

resource "azurerm_subnet" "logicapps" {
  name                 = "snet-logicapps-${local.loc_for_naming}"
  resource_group_name  = azurerm_virtual_network.default.resource_group_name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.4.0.64/26"]
  service_endpoints = [
    "Microsoft.Web",
    "Microsoft.Storage"
  ]
  delegation {
    name = "serverfarm-delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "pdns-blob"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "file" {
  name                  = "pdns-file"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.file.name
  virtual_network_id    = azurerm_virtual_network.default.id
}


module "logicapp" {
  source = "github.com/implodingduck/tfmodules//logicapp"
  name = local.la_name
  resource_group_name = azurerm_resource_group.rg.name
  resource_group_location = var.location
  subnet_id_logicapp = azurerm_subnet.logicapps.id
  subnet_id_pe = azurerm_subnet.pe.id
  tags = local.tags
}



resource "azurerm_eventhub_namespace" "ehn" {
  name                = "ehn${local.la_name}${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Basic"
  capacity            = 1

  tags = local.tags
}

resource "azurerm_eventhub" "eh" {
  name                = "eh${local.la_name}${var.environment}"
  namespace_name      = azurerm_eventhub_namespace.ehn.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = 1
  message_retention   = 1
}

module "cosmosdb" {
  source = "github.com/implodingduck/tfmodules//cosmosdb"
  name = local.la_name
  resource_group_name = azurerm_resource_group.rg.name
  resource_group_location = var.location
  tags = local.tags
}

resource "azurerm_key_vault" "kv" {
  name                        = "kv-${local.la_name}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name                   = "standard"
}

resource "azurerm_key_vault_access_policy" "current" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

   key_permissions = [
    "Create",
    "Get",
    "Purge",
    "Recover",
    "Delete"
  ]

  secret_permissions = [
    "Set",
    "Purge",
    "Get",
    "List",
    "Delete"
  ]

  certificate_permissions = [
    "Purge"
  ]

  storage_permissions = [
    "Purge"
  ]
}

resource "azurerm_key_vault_access_policy" "logicapp" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = module.logicapp.identity.principal_id 

  secret_permissions = [
    "Get",
    "List",
  ]

}

resource "azurerm_key_vault_secret" "cosmosdb" {
  name         = "cosmosdbconn"
  value        = module.cosmosdb.connection_strings.0
  key_vault_id = azurerm_key_vault.kv.id
}