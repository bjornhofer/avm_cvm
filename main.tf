# Example with acCLI: https://learn.microsoft.com/en-us/azure/confidential-computing/quick-create-confidential-vm-azure-cli

// Default stuff
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.name}"
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  address_space       = ["192.168.0.0/24"]
  location            = azurerm_resource_group.rg.location
  name                = "vnet-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  address_prefixes     = ["192.168.0.0/26"]
  name                 = "subnet-${local.name}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
}

# KeyVault
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  enable_rbac_authorization       = false
  enabled_for_deployment          = true
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = false
  location                        = azurerm_resource_group.rg.location
  name                            = "kv-${local.name}"
  purge_protection_enabled        = true
  resource_group_name             = azurerm_resource_group.rg.name
  sku_name                        = "premium"
  soft_delete_retention_days      = 7
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  depends_on = [
    azurerm_resource_group.rg
  ]
}

data "http" "exportpolicy" {
  url = "https://cvmprivatepreviewsa.blob.core.windows.net/cvmpublicpreviewcontainer/skr-policy.json"
}

// Key Vault Key creation
// Currently the "exportable" attribute is not supported by the azurerm_key_vault_key resource
// Two options for creating the key:
// 1. Use azapi_resource
// 2. Use azurerm_resource_group_template_deployment
// Both options are shown here

// Option 1: azapi_resource - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/azapi_resource
// Downside: Destroying the key is currently not implemented
/*
resource "azapi_resource" "key_vault_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2021-06-01-preview"
  name      = "key-${local.name}"
  parent_id = azurerm_key_vault.kv.id

  body = jsonencode({
    properties = {
      kty     = "RSA-HSM"
      keySize = 3072
      keyOps  = ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]
      attributes = {
        exportable = true
      },
      release_policy = {
        data : base64encode(data.http.exportpolicy.body)
      }
    }
  })
  lifecycle {
    ignore_changes = [body]
  }
}
*/

// Option 2: azurerm_resource_group_template_deployment - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_template_deployment
// Downside: More complex

resource "azurerm_resource_group_template_deployment" "cvm_deployment" {
  name                = "cvm_key_deployment"
  resource_group_name = azurerm_resource_group.rg.name
  deployment_mode     = "Incremental"
  template_content    = <<TEMPLATE
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.KeyVault/vaults/keys",
      "apiVersion": "2023-07-01",
      "name": "${azurerm_key_vault.kv.name}/key-${local.name}",
      "properties": {
        "kty": "RSA-HSM",
        "keySize": 3072,
        "keyOps": [
          "encrypt",
          "decrypt",
          "sign",
          "verify",
          "wrapKey",
          "unwrapKey"
        ],
        "attributes" : {
            "exportable" : true
        },
        "release_policy" : {
            "data" : "${base64encode(data.http.exportpolicy.body)}"
        }
      }
    }
  ]
}
TEMPLATE
}


# Assign permissions
data "azuread_service_principal" "cvm_orchestrator" {
  application_id = "bf7b6499-ff71-4aa2-97a4-f372087be7f0"
}

resource "azurerm_key_vault_access_policy" "cvm_orchestrator" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azuread_service_principal.cvm_orchestrator.object_id

  key_permissions = [
    "Get", "Release"
  ]
}

resource "azurerm_key_vault_access_policy" "current" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create", "Get", "Release", "List"
  ]
}

// Get information about the key
data "azurerm_key_vault_key" "des" {
  name         = "key-${local.name}"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on = [
    azurerm_key_vault_access_policy.current,
    azurerm_resource_group_template_deployment.cvm_deployment
  ]
}

// Disk Encryption Set - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/disk_encryption_set
resource "azurerm_disk_encryption_set" "des" {
  encryption_type     = "ConfidentialVmEncryptedWithCustomerKey"
  key_vault_key_id    = data.azurerm_key_vault_key.des.id
  location            = azurerm_resource_group.rg.location
  name                = "des-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  identity {
    type = "SystemAssigned"
  }
  depends_on = [
    azurerm_key_vault_access_policy.cvm_orchestrator
  ]
}

resource "azurerm_key_vault_access_policy" "des" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_disk_encryption_set.des.identity[0].principal_id
  key_permissions = [
    "WrapKey", "UnwrapKey", "Get", "List"
  ]
}

// VM relevant stuff
# NIC
resource "azurerm_network_interface" "nic" {
  name                = "nic-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
  depends_on = [
    azurerm_subnet.subnet
  ]
}

resource "azurerm_linux_virtual_machine" "cvm" {
  count               = var.os == "linux" ? 1 : 0
  name                = "vm-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  // CVM
  secure_boot_enabled = true
  vtpm_enabled        = true
  // Cannot be true according to documentation - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine#security_encryption_type
  encryption_at_host_enabled = false

  identity {
    type = "SystemAssigned"
  }

  admin_username = "azuser"
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_ssh_key {
    username   = "azuser"
    public_key = var.public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    //CVM
    secure_vm_disk_encryption_set_id = azurerm_disk_encryption_set.des.id
    security_encryption_type         = "DiskWithVMGuestState"
  }

  // CVM
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-confidential-vm-jammy"
    sku       = "22_04-lts-cvm"
    version   = "latest"
  }
  depends_on = [
    azurerm_network_interface.nic,
    azurerm_key_vault_access_policy.des
  ]
}

resource "azurerm_windows_virtual_machine" "cvm" {
  count               = var.os == "windows" ? 1 : 0
  name                = "vm-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  // CVM
  secure_boot_enabled = true
  vtpm_enabled        = true
  // Cannot be true according to documentation - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine#security_encryption_type
  encryption_at_host_enabled = false

  identity {
    type = "SystemAssigned"
  }

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_username = "azuser"
  admin_password = var.windows_password
  os_disk {
    name                 = "os-${local.name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    //CVM
    secure_vm_disk_encryption_set_id = azurerm_disk_encryption_set.des.id
    security_encryption_type         = "DiskWithVMGuestState"
  }

  // CVM
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-datacenter-smalldisk-g2"
    version   = "latest"
  }
  depends_on = [
    azurerm_network_interface.nic
  ]
}
