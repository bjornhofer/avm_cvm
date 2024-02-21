variable "name_base" {
    type = string
    default = null
}

variable "name_suffix" {
    type = string
    default = null
}

variable "location" {
    type = string
    default = "westeurope"
}

variable "os" {
  type = string
  default = "windows"
}

variable "public_key" {
  type = string
  default = null
}

variable "windows_password" {
  type = string
  default = null
}

// Nameing stuff - for fast recreation...
resource "random_integer" "random" {
  min = 1
  max = 9999
}

locals {
    base = var.name_base != null ? var.name_base : "cvm"
    name_suffix = var.name_suffix != null ? var.name_suffix : random_integer.random.result
    name = "${local.base}${local.name_suffix}"
}
