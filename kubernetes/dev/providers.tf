provider "helm" {
  kubernetes {
    host                   = var.platform.cluster_endpoint
    cluster_ca_certificate = base64decode(var.platform.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.platform.cluster_name, "--region", var.platform.region]
    }
  }
}

provider "aws" {
  region              = var.platform.region
  allowed_account_ids = [var.platform.account_id]
  default_tags { tags = var.platform.tags }
}
