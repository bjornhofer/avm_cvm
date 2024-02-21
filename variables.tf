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

// Nameing stuff - for fast recreation...
locals {
    base = var.name_base != null ? var.name_base : "cvm"
    name_suffix = var.name_suffix != null ? var.name_suffix : "01"
    name = "${local.base}${local.name_suffix}"
}
