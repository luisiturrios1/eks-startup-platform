provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = {
      "Environment" = var.environment
      "Project"     = var.project_name
      "ManagedBy"   = "Terraform"
      "Owner"       = var.owner
      "CostCenter"  = var.cost_center
    }
  }
}
