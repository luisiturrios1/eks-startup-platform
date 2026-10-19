# Disposable emulator credentials; never consult the operator's AWS profile.
provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true
  allowed_account_ids         = ["000000000000"]
  default_tags {
    tags = {
      Environment = "dev"
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Owner       = "platform-review"
      CostCenter  = "local-evaluation"
    }
  }
  endpoints {
    acm              = "http://127.0.0.1:14566"
    budgets          = "http://127.0.0.1:14566"
    cloudwatch       = "http://127.0.0.1:14566"
    cloudwatchlogs   = "http://127.0.0.1:14566"
    ec2              = "http://127.0.0.1:14566"
    ecr              = "http://127.0.0.1:14566"
    eks              = "http://127.0.0.1:14566"
    elasticache      = "http://127.0.0.1:14566"
    elbv2            = "http://127.0.0.1:14566"
    iam              = "http://127.0.0.1:14566"
    kms              = "http://127.0.0.1:14566"
    lambda           = "http://127.0.0.1:14566"
    rds              = "http://127.0.0.1:14566"
    route53          = "http://127.0.0.1:14566"
    s3               = "http://127.0.0.1:14566"
    secretsmanager   = "http://127.0.0.1:14566"
    sns              = "http://127.0.0.1:14566"
    sqs              = "http://127.0.0.1:14566"
    sts              = "http://127.0.0.1:14566"
    wafv2            = "http://127.0.0.1:14566"
    cloudwatchevents = "http://127.0.0.1:14566"
  }
}
