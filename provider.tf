provider "azurerm" {
  features {
    // Keep ARM resources when destroying Terraform-managed infrastructure. https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block#delete_nested_items_during_deletion
    template_deployment {
      delete_nested_items_during_deletion = false
    }
  }
}

provider "azapi" {}