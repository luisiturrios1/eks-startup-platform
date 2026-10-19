terraform {
  required_version = ">= 1.14, < 2.0"
  backend "local" {}
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
