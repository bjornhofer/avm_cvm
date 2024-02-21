// Default stuff
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.name}"
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  address_space = ["192.168.0.0/24"]
  location      = azurerm_resource_group.rg.location
  name          = "vnet-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  address_prefixes = ["192.168.0.0/26"]
  name             = "subnet-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
}

// Security relevant stuff
// Attestation provider
// Missing step - register Azure resource provider
// Attestation must be registered - https://aka.ms/rps-not-found

resource "tls_private_key" "signing_cert" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "attestation" {
  private_key_pem      = tls_private_key.signing_cert.private_key_pem
  validity_period_hours = 12
  allowed_uses         = ["cert_signing"]
}

// need to review ignore_changes part, why this is happening
resource "azurerm_attestation_provider" "ap" {
  location                  = azurerm_resource_group.rg.location
  name                      = "aap${local.name}"
  resource_group_name       = azurerm_resource_group.rg.name
  policy_signing_certificate_data = tls_self_signed_cert.attestation.cert_pem
  lifecycle {
   ignore_changes = [
     open_enclave_policy_base64,
     sgx_enclave_policy_base64,
     tpm_policy_base64,
     sev_snp_policy_base64
   ]
  }
}

# KeyVault
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  enable_rbac_authorization       = true
  enabled_for_deployment          = false
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

resource "azurerm_key_vault_key" "key" {
  key_opts     = ["sign", "verify", "wrapKey", "unwrapKey", "encrypt", "decrypt"]
  key_size     = 2048
  key_type     = "RSA-HSM"
  key_vault_id = azurerm_key_vault.kv.id
  name         = "key-${local.name}"
  depends_on = [
    azurerm_key_vault.kv,
    azurerm_role_assignment.current
  ]
}

# Service principal
// Temporary disabled
/*
resource "azuread_service_principal" "sp" {
  application_id = "bf7b6499-ff71-4aa2-97a4-f372087be7f0"
}
*/

# Assign permissions

resource "azurerm_disk_encryption_set" "des" {
  encryption_type = "ConfidentialVmEncryptedWithCustomerKey"
  key_vault_key_id = azurerm_key_vault_key.key.id
  location = azurerm_resource_group.rg.location
  name = "des-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  identity {
    type = "SystemAssigned"
  }
  depends_on = [
    azurerm_key_vault.kv,
    azurerm_key_vault_key.key
  ]
}

// Permissions for DES
# We do not use KeyVault policiese -> RBAC
resource "azurerm_role_assignment" "current" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

// Add role for DES - according to documentation -> https://registry.terraform.io/providers/hashicorp/azurerm/3.92.0/docs/resources/disk_encryption_set
resource "azurerm_role_assignment" "des" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.des.identity.0.principal_id
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
}

resource "azurerm_linux_virtual_machine" "cvm" {
  count              = var.os == "linux" ? 1 : 0
  name                = "vm-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_DC2ads_v5"
  // CVM
  secure_boot_enabled = true
  vtpm_enabled = true
  // Cannot be true according to documentation - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine#security_encryption_type
  encryption_at_host_enabled = false

  identity {
    type = "SystemAssigned"
  }

  admin_username      = "azuser"
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
    security_encryption_type = "DiskWithVMGuestState"
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
    azurerm_role_assignment.des
  ]
}

resource "azurerm_windows_virtual_machine" "cvm" {
  count              = var.os == "windows" ? 1 : 0
  name                = "vm-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_DC2ads_v5"
  // CVM
  secure_boot_enabled = true
  vtpm_enabled = true
  // Cannot be true according to documentation - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine#security_encryption_type
  encryption_at_host_enabled = false

  identity {
    type = "SystemAssigned"
  }

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_username      = "azuser"
  admin_password = var.windows_password
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    //CVM
    secure_vm_disk_encryption_set_id = azurerm_disk_encryption_set.des.id
    security_encryption_type = "DiskWithVMGuestState"
  }

  // CVM
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-datacenter-smalldisk-g2"
    version   = "latest"
  }
  depends_on = [ 
    azurerm_network_interface.nic,
    azurerm_role_assignment.des
  ]
}

resource "azurerm_virtual_machine_extension" "cvm" {
  name                 = "GuestAttestation"
  virtual_machine_id   = azurerm_windows_virtual_machine.cvm[0].id
  publisher            = "Microsoft.Azure.Security.WindowsAttestation"
  type                 = "GuestAttestation"
  type_handler_version = "1.0"

  settings = <<SETTINGS
      {
        "attestationMode": "Attestation",
        "attestationUrl": "${azurerm_attestation_provider.ap.attestation_uri}"
      }
    SETTINGS
}