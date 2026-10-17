provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = {
      "ManagedBy"   = "Terraform"
      "Project"     = "startup"
      "Environment" = "bootstrap"
      "Owner"       = var.owner
      "CostCenter"  = var.cost_center
    }
  }
}
