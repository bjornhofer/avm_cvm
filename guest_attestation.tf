/*
# Non functional - deactived
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
*/