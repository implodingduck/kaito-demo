terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.22.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source = "azure/azapi"
      version = "=2.3.0"
    }
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

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-${local.loc_short}"
  resource_group_name = "DefaultResourceGroup-${local.loc_short}"
} 

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}



resource "azurerm_virtual_network" "default" {
  name                = "${local.cluster_name}-vnet-eastus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.37.0.0/16"]

  tags = local.tags
}


resource "azurerm_subnet" "default" {
  name                 = "default-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.37.0.0/24"]
}

resource "azurerm_subnet" "cluster" {
  name                 = "${local.cluster_name}-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.37.2.0/24"]

}

data "azurerm_kubernetes_service_versions" "current" {
  location = azurerm_resource_group.rg.location
  include_preview = false
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                    = "${local.cluster_name}"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  dns_prefix              = "${local.cluster_name}"
  kubernetes_version      = data.azurerm_kubernetes_service_versions.current.latest_version
  private_cluster_enabled = false
  default_node_pool {
    name            = "default"
    node_count      = 1
    vm_size         = "Standard_B4ms"
    os_disk_size_gb = "128"
    vnet_subnet_id  = azurerm_subnet.cluster.id
    max_pods        = 60
    upgrade_settings {
        drain_timeout_in_minutes      = 0
        max_surge                     = "10%"
        node_soak_duration_in_minutes = 0
    }

  }
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "192.168.0.0/16"
    service_cidr       = "10.255.252.0/22"
    dns_service_ip     = "10.255.252.10"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
    secret_rotation_interval = "5m"
  }

  role_based_access_control_enabled = false

  identity {
    type = "SystemAssigned"
  }
  
  oidc_issuer_enabled = true
  workload_identity_enabled = true
  oms_agent {
    log_analytics_workspace_id = data.azurerm_log_analytics_workspace.default.id
  }

  tags = local.tags

}

resource "azurerm_container_registry" "acr" {
  name                = "acr${local.cluster_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
  admin_enabled       = false
  tags = local.tags
}


resource "azurerm_role_assignment" "acrpull_role" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "acrpush_role" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPush"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.cluster_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

}

resource "azurerm_role_assignment" "kv_officer" {
  scope                            = azurerm_key_vault.kv.id
  role_definition_name             = "Key Vault Secrets Officer"
  principal_id                     = data.azurerm_client_config.current.object_id
}

resource "azapi_update_resource" "aiToolchainOperatorProfile" {
    type        = "Microsoft.ContainerService/managedClusters@2024-09-02-preview"
    resource_id = azurerm_kubernetes_cluster.aks.id

    body = {
        properties = {
            aiToolchainOperatorProfile = {
                enabled = true
            }
        }
    }
}

data "azurerm_user_assigned_identity" "kaitoprovisioner" {
    depends_on = [ azapi_update_resource.aiToolchainOperatorProfile ]
    name                = "ai-toolchain-operator-${local.cluster_name}"
    resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
}

resource "azurerm_federated_identity_credential" "example" {
  name                = "kaito-gpu-provisioner"
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  parent_id           = data.azurerm_user_assigned_identity.kaitoprovisioner.id
  subject             = "system:serviceaccount:kube-system:kaito-gpu-provisioner"
}

resource "azurerm_role_assignment" "contributor" {
    depends_on = [ azapi_update_resource.aiToolchainOperatorProfile ]
    scope                            = azurerm_kubernetes_cluster.aks.node_resource_group_id
    role_definition_name             = "Contributor"
    principal_id                     = data.azurerm_user_assigned_identity.kaitoprovisioner.principal_id
}