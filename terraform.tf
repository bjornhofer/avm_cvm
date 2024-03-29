terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.65.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.0.4"
    }

    azapi = {
      source  = "Azure/azapi"
      version = ">=0.1"
    }
  }
}
