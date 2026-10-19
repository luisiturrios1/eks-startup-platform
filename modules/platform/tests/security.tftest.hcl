mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_availability_zones" { defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] } }
  mock_resource "aws_kms_key" {
    override_during = plan
    defaults        = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_secretsmanager_secret" {
    override_during = plan
    defaults        = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:mock-abcdef" }
  }
  mock_resource "aws_iam_role" {
    override_during = plan
    defaults        = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_eks_cluster" {
    override_during = plan
    defaults        = { certificate_authority = [{ data = "dGVzdA==" }], arn = "arn:aws:eks:us-east-1:111111111111:cluster/test", identity = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST" }] }] }
  }
  mock_resource "aws_sqs_queue" {
    override_during = plan
    defaults        = { arn = "arn:aws:sqs:us-east-1:111111111111:test" }
  }
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
    condition     = aws_elasticache_replication_group.this[0].engine == "valkey" && aws_elasticache_replication_group.this[0].transit_encryption_enabled
    error_message = "Managed Valkey TLS required."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.karpenter.policy).Statement :
      !try(contains(statement.Action, "ec2:CreateTags"), statement.Action == "ec2:CreateTags") ||
      try(length(statement.Condition.StringEquals["ec2:CreateAction"]) > 0, false) ||
      (try(statement.Condition.StringEquals["aws:ResourceTag/kubernetes.io/cluster/startup-dev"] == "owned", false) &&
        try(statement.Condition.StringLike["aws:ResourceTag/karpenter.sh/nodepool"] == "*", false) &&
      try(alltrue([for key in statement.Condition["ForAllValues:StringEquals"]["aws:TagKeys"] : contains(["Name", "karpenter.sh/nodeclaim", "eks:eks-cluster-name"], key)]), false))
    ])
    error_message = "Every emitted CreateTags grant must prevent unrelated resources gaining deletion-authorizing ownership."
  }
  assert {
    condition     = local.karpenter_tagging_statements[0].Condition.StringEquals["ec2:CreateAction"] == ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    error_message = "CreateTags must only set ownership tags during resource creation."
  }
  assert {
    condition     = local.karpenter_tagging_statements[1].Condition.StringEquals["aws:ResourceTag/kubernetes.io/cluster/startup-dev"] == "owned" && local.karpenter_tagging_statements[1].Condition.StringLike["aws:ResourceTag/karpenter.sh/nodepool"] == "*" && alltrue([for key in local.karpenter_tagging_statements[1].Condition["ForAllValues:StringEquals"]["aws:TagKeys"] : !contains(["kubernetes.io/cluster/startup-dev", "karpenter.sh/nodepool"], key)])
    error_message = "Existing instances require prior ownership and cannot gain ownership/deletion tags through tag updates."
  }

  assert {
    condition = alltrue([for name, role in aws_iam_role.runtime :
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == name &&
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "runtime" &&
      aws_eks_pod_identity_association.runtime[name].namespace == name &&
      aws_eks_pod_identity_association.runtime[name].service_account == "runtime"
    ])
    error_message = "Runtime trust must bind to the exact service namespace and runtime account."
  }
  assert {
    condition = alltrue([for name, role in aws_iam_role.migration :
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == name &&
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "migration" &&
      aws_eks_pod_identity_association.migration[name].namespace == name &&
      aws_eks_pod_identity_association.migration[name].service_account == "migration"
    ])
    error_message = "Migration trust must remain isolated from runtime and other services."
  }
  assert {
    condition = alltrue([for name, policy in aws_iam_role_policy.migration :
      length(jsondecode(policy.policy).Statement) == 2 &&
      jsondecode(policy.policy).Statement[0].Resource == aws_secretsmanager_secret.migration[name].arn
    ])
    error_message = "Migration roles must only read their own credential secret and decrypt via Secrets Manager."
  }

}

run "optional_permissions_disabled" {
  command = plan
  variables {
    services = { "auth-service" = { "apiVersion" = "platform/v1", "name" = "auth-service", "domain" = "auth", "image" = "111111111111.dkr.ecr.us-east-1.amazonaws.com/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "port" = 8443, "resources" = { "requests" = { "cpu" = "250m", "memory" = "512Mi" }, "limits" = { "cpu" = "1000m", "memory" = "1Gi" } }, "scaling" = { "minReplicas" = 2, "maxReplicas" = 6, "cpuUtilization" = 70 }, "database" = { "placement" = "shared", "group" = "auth", "name" = "auth_service" }, "permissions" = { "s3" = [], "cache" = false }, "dependencies" = [], "migration" = { "command" = ["java", "-jar", "/app/app.jar", "--spring.profiles.active=migration"] }, "database_key" = "shared-auth", "engine" = "mysql" }, "payments-service" = { "apiVersion" = "platform/v1", "name" = "payments-service", "domain" = "payments", "image" = "111111111111.dkr.ecr.us-east-1.amazonaws.com/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "port" = 8443, "resources" = { "requests" = { "cpu" = "250m", "memory" = "512Mi" }, "limits" = { "cpu" = "1000m", "memory" = "1Gi" } }, "scaling" = { "minReplicas" = 2, "maxReplicas" = 6, "cpuUtilization" = 70 }, "database" = { "placement" = "shared", "group" = "payments", "name" = "payments_service" }, "permissions" = { "s3" = [], "cache" = false }, "dependencies" = [], "migration" = { "command" = ["java", "-jar", "/app/app.jar", "--spring.profiles.active=migration"] }, "database_key" = "shared-payments", "engine" = "postgres" } }
  }
  assert {
    condition     = length(aws_s3_bucket.service) == 0 && length(aws_elasticache_user.service) == 0 && length(aws_elasticache_replication_group.this) == 0 && length(aws_elasticache_subnet_group.this) == 0 && length(aws_elasticache_user_group.this) == 0 && length(aws_elasticache_user.disabled) == 0 && length(aws_cloudwatch_metric_alarm.cache_memory) == 0
    error_message = "Disabled optional service resources must not create buckets, cache infrastructure, users or alarms."
  }
  assert {
    condition     = alltrue([for service in output.services : service.cache_host == "" && service.cache_resource == "" && service.cache_user == ""])
    error_message = "Services without cache permission must not receive cache connection metadata."
  }
}

run "mixed_cache_permissions" {
  command = plan
  variables {
    services = { for name, service in var.services : name => merge(service, {
      permissions = { s3 = service.permissions.s3, cache = name == "payments-service" }
    }) }
  }
  assert {
    condition     = length(aws_elasticache_replication_group.this) == 1 && length(aws_elasticache_user.service) == 1 && contains(keys(aws_elasticache_user.service), "payments-service")
    error_message = "One remaining consumer must retain the shared cache and only its identity."
  }
  assert {
    condition     = output.services["auth-service"].cache_host == "" && output.services["auth-service"].cache_resource == "" && output.services["auth-service"].cache_user == ""
    error_message = "A non-consumer must not receive another service's cache connection metadata."
  }
}

run "foreign_service_image_rejected" {
  command = plan
  variables {
    services = { for name, service in var.services : name => merge(service, {
      image = "222222222222.dkr.ecr.us-east-1.amazonaws.com/foreign@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }) }
  }
  expect_failures = [var.services]
}

run "foreign_rotation_image_rejected" {
  command = plan
  variables {
    rotation_image_uri = "222222222222.dkr.ecr.us-east-1.amazonaws.com/foreign@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [var.rotation_image_uri]
}
