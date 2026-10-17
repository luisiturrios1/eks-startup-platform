mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_availability_zones" { defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] } }
  mock_resource "aws_kms_key" { defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111111111111:role/mock" } }
  mock_resource "aws_eks_cluster" { defaults = { arn = "arn:aws:eks:us-east-1:111111111111:cluster/test", identity = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST" }] }] } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:test" } }
}
variables {
  availability_zone_ids      = ["use1-az1", "use1-az2", "use1-az4"]
  environment                = "dev"
  account_id                 = "111111111111"
  production_account_id      = "333333333333"
  owner                      = "platform-team"
  cost_center                = "engineering"
  vpc_cidr                   = "10.40.0.0/16"
  vpn_client_cidr            = "10.250.0.0/22"
  vpn_server_certificate_arn = "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"
  vpn_saml_provider_arn      = "arn:aws:iam::111111111111:saml-provider/company"
  vpn_group                  = "platform-admins"
  admin_role_arn             = "arn:aws:iam::111111111111:role/platform-admin"
  certificate_arn            = "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000001"
  hosted_zone_id             = "Z0123456789012"
  domain_name                = "example.com"
  budget_usd                 = 1000
  alert_email                = "platform@example.com"
  rotation_image_uri         = "111111111111.dkr.ecr.us-east-1.amazonaws.com/platform-artifacts@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  addons                     = { "vpc-cni" = "v1.20.0-eksbuild.1", "kube-proxy" = "v1.35.0-eksbuild.1", "coredns" = "v1.12.0-eksbuild.1", "eks-pod-identity-agent" = "v1.3.0-eksbuild.1" }
  services                   = { "auth-service" = { "apiVersion" = "platform/v1", "name" = "auth-service", "domain" = "auth", "image" = "111111111111.dkr.ecr.us-east-1.amazonaws.com/auth-service@sha256:0000000000000000000000000000000000000000000000000000000000000000", "port" = 8443, "resources" = { "requests" = { "cpu" = "250m", "memory" = "512Mi" }, "limits" = { "cpu" = "1000m", "memory" = "1Gi" } }, "scaling" = { "minReplicas" = 2, "maxReplicas" = 6, "cpuUtilization" = 70 }, "database" = { "placement" = "shared", "group" = "auth", "name" = "auth_service" }, "permissions" = { "s3" = ["read", "write"], "cache" = true }, "dependencies" = [], "migration" = { "command" = ["java", "-jar", "/app/app.jar", "--spring.profiles.active=migration"] }, "database_key" = "shared-auth", "engine" = "mysql" }, "payments-service" = { "apiVersion" = "platform/v1", "name" = "payments-service", "domain" = "payments", "image" = "111111111111.dkr.ecr.us-east-1.amazonaws.com/payments-service@sha256:0000000000000000000000000000000000000000000000000000000000000000", "port" = 8443, "resources" = { "requests" = { "cpu" = "250m", "memory" = "512Mi" }, "limits" = { "cpu" = "1000m", "memory" = "1Gi" } }, "scaling" = { "minReplicas" = 2, "maxReplicas" = 6, "cpuUtilization" = 70 }, "database" = { "placement" = "shared", "group" = "payments", "name" = "payments_service" }, "permissions" = { "s3" = ["read", "write"], "cache" = true }, "dependencies" = [], "migration" = { "command" = ["java", "-jar", "/app/app.jar", "--spring.profiles.active=migration"] }, "database_key" = "shared-payments", "engine" = "postgres" } }
  database_instances         = { "shared-auth" = { "domain" = "auth", "engine" = "mysql", "engine_version" = "8.4", "instance_class" = "db.t4g.medium", "storage_gb" = 20, "multi_az" = false }, "shared-payments" = { "domain" = "payments", "engine" = "postgres", "engine_version" = "17", "instance_class" = "db.t4g.medium", "storage_gb" = 20, "multi_az" = false } }
}
run "private_platform" {
  command = plan
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false
    error_message = "EKS must be private."
  }
  assert {
    condition     = alltrue([for db in aws_db_instance.this : !db.publicly_accessible && db.storage_encrypted && db.manage_master_user_password && db.deletion_protection])
    error_message = "Database security requirements missing."
  }
  assert {
    condition     = length(aws_db_instance.this) == 2 && aws_db_instance.this["shared-payments"].engine == "postgres" && aws_db_instance.this["shared-auth"].engine == "mysql"
    error_message = "Domain database placement is incorrect."
  }
  assert {
    condition     = aws_elasticache_replication_group.this.engine == "valkey" && aws_elasticache_replication_group.this.transit_encryption_enabled
    error_message = "Managed Valkey TLS required."
  }
}

run "optional_permissions_disabled" {
  command = plan
  variables {
    services = { "auth-service" = { "apiVersion" = "platform/v1", "name" = "auth-service", "domain" = "auth", "image" = "111111111111.dkr.ecr.us-east-1.amazonaws.com/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "port" = 8443, "resources" = { "requests" = { "cpu" = "250m", "memory" = "512Mi" }, "limits" = { "cpu" = "1000m", "memory" = "1Gi" } }, "scaling" = { "minReplicas" = 2, "maxReplicas" = 6, "cpuUtilization" = 70 }, "database" = { "placement" = "shared", "group" = "auth", "name" = "auth_service" }, "permissions" = { "s3" = [], "cache" = false }, "dependencies" = [], "migration" = { "command" = ["java", "-jar", "/app/app.jar", "--spring.profiles.active=migration"] }, "database_key" = "shared-auth", "engine" = "mysql" }, "payments-service" = { "apiVersion" = "platform/v1", "name" = "payments-service", "domain" = "payments", "image" = "111111111111.dkr.ecr.us-east-1.amazonaws.com/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "port" = 8443, "resources" = { "requests" = { "cpu" = "250m", "memory" = "512Mi" }, "limits" = { "cpu" = "1000m", "memory" = "1Gi" } }, "scaling" = { "minReplicas" = 2, "maxReplicas" = 6, "cpuUtilization" = 70 }, "database" = { "placement" = "shared", "group" = "payments", "name" = "payments_service" }, "permissions" = { "s3" = [], "cache" = false }, "dependencies" = [], "migration" = { "command" = ["java", "-jar", "/app/app.jar", "--spring.profiles.active=migration"] }, "database_key" = "shared-payments", "engine" = "postgres" } }
  }
  assert {
    condition     = length(aws_s3_bucket.service) == 0 && length(aws_elasticache_user.service) == 0
    error_message = "Disabled optional service resources must not create buckets or cache users."
  }
}
