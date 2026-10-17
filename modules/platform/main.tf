locals {
  common_tags   = { Environment = var.environment, Project = var.project_name, ManagedBy = "Terraform", Owner = var.owner, CostCenter = var.cost_center }
  name          = "${var.project_name}-${var.environment}"
  production    = var.environment == "prod"
  cache_enabled = anytrue([for service in var.services : service.permissions.cache])
  partition     = data.aws_partition.current.partition
  trust_pods    = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"], Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = aws_eks_cluster.this.arn } } }] })
}

data "aws_partition" "current" {

}

data "aws_caller_identity" "current" {

}

module "network" {
  availability_zone_ids      = var.availability_zone_ids
  source                     = "../networking"
  region                     = var.region
  account_id                 = var.account_id
  cidr                       = var.vpc_cidr
  vpn_server_certificate_arn = var.vpn_server_certificate_arn
  vpn_saml_provider_arn      = var.vpn_saml_provider_arn
  vpn_group                  = var.vpn_group
  vpn_client_cidr            = var.vpn_client_cidr
  name                       = local.name
  log_key_arn                = aws_kms_key.platform.arn
}

resource "aws_kms_key" "platform" {
  description             = "Platform data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = jsonencode({ Version = "2012-10-17", Statement = [{ Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:${local.partition}:iam::${var.account_id}:root" }, Action = "kms:*", Resource = "*" }, { Sid = "RegionalLogs", Effect = "Allow", Principal = { Service = "logs.${var.region}.amazonaws.com" }, Action = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*", Condition = { ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${var.region}:${var.account_id}:log-group:*" } } }] })
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.platform.id
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-node"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role" "cni" {
  name               = "${local.name}-cni"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node", "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com" } } }] })
}

resource "aws_iam_role" "runtime" {
  for_each           = var.services
  name               = "${local.name}-${each.key}-runtime"
  assume_role_policy = local.trust_pods
}

resource "aws_iam_role" "migration" {
  for_each           = var.services
  name               = "${local.name}-${each.key}-migration"
  assume_role_policy = local.trust_pods
}

resource "aws_iam_role" "credentials" {
  name               = "${local.name}-credentials"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role" "karpenter" {
  name               = "${local.name}-karpenter"
  assume_role_policy = local.trust_pods
}

resource "aws_iam_role" "load-balancer" {
  name               = "${local.name}-load-balancer"
  assume_role_policy = local.trust_pods
}

resource "aws_iam_role" "telemetry" {
  name               = "${local.name}-telemetry"
  assume_role_policy = local.trust_pods
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${local.name}-karpenter-node"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_cloudwatch_log_group" "credentials" {
  name              = "/aws/lambda/${local.name}-credentials"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_cloudwatch_log_group" "apps" {
  #checkov:skip=CKV_AWS_338:Application logs retain 30 days; audit logs retain 365. No one-year application retention requirement. See docs/security-exceptions.md.
  name              = "/platform/${local.name}/applications"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_338:WAF request logs retain 30 days with redaction; audit logs retain 365. See docs/security-exceptions.md.
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_eks_cluster" "this" {
  tags                      = { Owner = var.owner, CostCenter = var.cost_center }
  name                      = local.name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  kubernetes_network_config {
    ip_family = "ipv4"
  }
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  vpc_config {
    subnet_ids              = module.network.application_subnets
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [module.network.security_groups.api]
  }
  encryption_config {
    provider {
      key_arn = aws_kms_key.platform.arn
    }
    resources = ["secrets"]
  }
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.eks]
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id && (local.production ? var.account_id == var.production_account_id : var.account_id != var.production_account_id)
      error_message = "Expected account isolation must hold before provisioning."
    }
  }
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admin]
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name}-node"
  role = aws_iam_role.karpenter_node.name
}

resource "aws_launch_template" "system" {
  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }
  name_prefix            = "${local.name}-system-"
  vpc_security_group_ids = [module.network.security_groups.nodes]
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = module.network.application_subnets
  instance_types  = [var.system_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  update_config {
    max_unavailable = 1
  }
  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }
  labels = {
    "platform/system" = "true"
  }
  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.cni, aws_eks_addon.proxy]
}

resource "aws_iam_openid_connect_provider" "eks" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_eks_addon" "cni" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "vpc-cni"
  addon_version            = var.addons["vpc-cni"]
  service_account_role_arn = aws_iam_role.cni.arn
  configuration_values     = jsonencode({ enableNetworkPolicy = "true", env = { NETWORK_POLICY_ENFORCING_MODE = "strict" } })
  depends_on               = [aws_iam_role_policy_attachment.cni]
}

resource "aws_eks_addon" "proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = var.addons["kube-proxy"]
}

resource "aws_eks_addon" "runtime" {
  for_each      = toset(["eks-pod-identity-agent"])
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = var.addons[each.key]
  depends_on    = [aws_eks_node_group.system]
  # Protect the old CoreDNS instance until an explicitly authorized cross-root transfer.
  lifecycle { prevent_destroy = true }
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.network.database_subnets
}

resource "aws_db_parameter_group" "this" {
  for_each    = var.database_instances
  name_prefix = "${local.name}-${each.key}-"
  family      = each.value.engine == "postgres" ? "postgres${split(".", each.value.engine_version)[0]}" : "mysql${join(".", slice(split(".", each.value.engine_version), 0, 2))}"
  parameter {
    name         = each.value.engine == "postgres" ? "rds.force_ssl" : "require_secure_transport"
    value        = "1"
    apply_method = "pending-reboot"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  depends_on = [aws_cloudwatch_log_group.rds]
  #checkov:skip=CKV2_AWS_69:Engine-selected parameter group enforces rds.force_ssl or require_secure_transport; static scanner cannot resolve shared group engine.
  iam_database_authentication_enabled   = true
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.platform.arn
  performance_insights_retention_period = 7
  for_each                              = var.database_instances
  identifier                            = "${local.name}-${each.key}"
  engine                                = each.value.engine
  engine_version                        = each.value.engine_version
  instance_class                        = each.value.instance_class
  allocated_storage                     = each.value.storage_gb
  max_allocated_storage                 = each.value.storage_gb * 3
  storage_type                          = "gp3"
  storage_encrypted                     = true
  kms_key_id                            = aws_kms_key.platform.arn
  username                              = "platform_admin"
  manage_master_user_password           = true
  master_user_secret_kms_key_id         = aws_kms_key.platform.arn
  db_subnet_group_name                  = aws_db_subnet_group.this.name
  vpc_security_group_ids                = [module.network.security_groups.database]
  parameter_group_name                  = aws_db_parameter_group.this[each.key].name
  publicly_accessible                   = false
  multi_az                              = local.production || each.value.multi_az
  backup_retention_period               = 7
  backup_window                         = "03:00-04:00"
  maintenance_window                    = "sun:05:00-sun:06:00"
  copy_tags_to_snapshot                 = true
  deletion_protection                   = true
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "${local.name}-${each.key}-final"
  auto_minor_version_upgrade            = true
  allow_major_version_upgrade           = false
  apply_immediately                     = false
  enabled_cloudwatch_logs_exports       = each.value.engine == "postgres" ? ["postgresql", "upgrade"] : ["error", "slowquery"]
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "runtime" {
  #checkov:skip=CKV2_AWS_57:EventBridge invokes tested alternating-user rotation every 30 days with DLQ and alarms; native rotation hook is not used.
  for_each                = var.services
  name                    = "${local.name}/${each.key}/database/runtime"
  kms_key_id              = aws_kms_key.platform.arn
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "migration" {
  #checkov:skip=CKV2_AWS_57:EventBridge invokes tested alternating-user rotation every 30 days with DLQ and alarms; native rotation hook is not used.
  for_each                = var.services
  name                    = "${local.name}/${each.key}/database/migration"
  kms_key_id              = aws_kms_key.platform.arn
  recovery_window_in_days = 30
}

resource "aws_elasticache_subnet_group" "this" {
  count      = local.cache_enabled ? 1 : 0
  name       = local.name
  subnet_ids = module.network.database_subnets
}

resource "aws_elasticache_user" "disabled" {
  count         = local.cache_enabled ? 1 : 0
  user_id       = "${local.name}-default"
  user_name     = "default"
  engine        = "valkey"
  access_string = "off ~* -@all"
  authentication_mode {
    type = "no-password-required"
  }
}

resource "aws_elasticache_user" "service" {
  for_each      = { for k, v in var.services : k => v if v.permissions.cache }
  user_id       = "${local.name}-${each.key}"
  user_name     = "${local.name}-${each.key}"
  engine        = "valkey"
  access_string = "on ~${each.key}:* -@all +get +set +setex +del +expire +ttl +ping"
  authentication_mode {
    type = "iam"
  }
}

resource "aws_elasticache_user_group" "this" {
  count         = local.cache_enabled ? 1 : 0
  engine        = "valkey"
  user_group_id = local.name
  user_ids      = concat([aws_elasticache_user.disabled[0].user_id], [for u in aws_elasticache_user.service : u.user_id])
}

resource "aws_elasticache_replication_group" "this" {
  count                      = local.cache_enabled ? 1 : 0
  replication_group_id       = local.name
  description                = "AWS-managed per-environment Valkey"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = var.cache_node_type
  num_cache_clusters         = local.production ? 2 : 1
  automatic_failover_enabled = local.production
  multi_az_enabled           = local.production
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this[0].name
  security_group_ids         = [module.network.security_groups.cache]
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.platform.arn
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  user_group_ids             = [aws_elasticache_user_group.this[0].user_group_id]
  snapshot_retention_limit   = 7
  auto_minor_version_upgrade = true
  apply_immediately          = false
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "service" {
  #checkov:skip=CKV2_AWS_62:No event consumer exists; bucket notifications would add unused infrastructure.
  #checkov:skip=CKV_AWS_144:Single-region recovery baseline; versioning and retention enabled, cross-region replication not required.
  for_each      = { for k, v in var.services : k => v if length(v.permissions.s3) > 0 }
  bucket        = "${local.name}-${each.key}-${var.account_id}"
  force_destroy = false
}

resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV2_AWS_62:Audit destination has no event consumer.
  #checkov:skip=CKV_AWS_144:Single-region recovery baseline with versioned audit retention.
  #checkov:skip=CKV_AWS_145:ALB access logs require SSE-S3; bucket remains encrypted and private. See docs/security-exceptions.md.
  bucket        = "${local.name}-access-${var.account_id}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "service" {
  for_each                = aws_s3_bucket.service
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "service" {
  for_each = aws_s3_bucket.service
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "service" {
  for_each = aws_s3_bucket.service
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "service" {
  for_each = aws_s3_bucket.service
  bucket   = each.value.id
  rule {
    id     = "bounded-noncurrent-storage"
    status = "Enabled"
    filter {
      prefix = ""
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
    id     = "retention"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "service" {
  for_each = aws_s3_bucket.service
  bucket   = each.value.id
  policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [each.value.arn, "${each.value.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }, { Effect = "Deny", Principal = "*", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"], Resource = [each.value.arn, "${each.value.arn}/*"], Condition = { StringNotEquals = { "aws:SourceVpce" = module.network.s3_endpoint_id }, Bool = { "aws:PrincipalIsAWSService" = "false" } } }] })
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "logging.s3.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.access_logs.arn}/s3/*", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } }, { Effect = "Allow", Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.access_logs.arn}/alb/AWSLogs/${var.account_id}/*" }, { Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}

resource "aws_ecr_repository" "service" {
  for_each             = toset(keys(var.services))
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.platform.arn
  }
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = false
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name
  policy     = "{\"rules\": [{\"rulePriority\": 1, \"description\": \"Expire abandoned untagged images\", \"selection\": {\"tagStatus\": \"untagged\", \"countType\": \"sinceImagePushed\", \"countUnit\": \"days\", \"countNumber\": 14}, \"action\": {\"type\": \"expire\"}}]}"
}

resource "aws_eks_pod_identity_association" "runtime" {
  for_each        = var.services
  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.key
  service_account = "runtime"
  role_arn        = aws_iam_role.runtime[each.key].arn
}

resource "aws_eks_pod_identity_association" "migration" {
  for_each        = var.services
  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.key
  service_account = "migration"
  role_arn        = aws_iam_role.migration[each.key].arn
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter.arn
}

resource "aws_eks_pod_identity_association" "load-balancer" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load-balancer.arn
}

resource "aws_eks_pod_identity_association" "telemetry" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "amazon-cloudwatch"
  service_account = "telemetry"
  role_arn        = aws_iam_role.telemetry.arn
}

resource "aws_iam_role_policy" "runtime" {
  for_each = var.services
  role     = aws_iam_role.runtime[each.key].id
  policy   = jsonencode({ Version = "2012-10-17", Statement = concat([{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = concat([aws_secretsmanager_secret.runtime[each.key].arn], each.value.secretReferences) }, { Effect = "Allow", Action = "kms:Decrypt", Resource = aws_kms_key.platform.arn, Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" } } }], [for statement in [{ Effect = "Allow", Action = "s3:ListBucket", Resource = try(aws_s3_bucket.service[each.key].arn, "") }, { Effect = "Allow", Action = concat(contains(each.value.permissions.s3, "read") ? ["s3:GetObject"] : [], contains(each.value.permissions.s3, "write") ? ["s3:PutObject"] : []), Resource = "${try(aws_s3_bucket.service[each.key].arn, "")}/*" }, { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.platform.arn, Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } } }] : statement if length(each.value.permissions.s3) > 0], each.value.permissions.cache ? [{ Effect = "Allow", Action = "elasticache:Connect", Resource = [aws_elasticache_replication_group.this[0].arn, aws_elasticache_user.service[each.key].arn] }] : []) })
}

resource "aws_iam_role_policy" "migration" {
  for_each = var.services
  role     = aws_iam_role.migration[each.key].id
  policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = aws_secretsmanager_secret.migration[each.key].arn }, { Effect = "Allow", Action = "kms:Decrypt", Resource = aws_kms_key.platform.arn, Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" } } }] })
}

resource "aws_iam_role_policy" "credentials" {
  #checkov:skip=CKV_AWS_290:Lambda ENI lifecycle requires EC2 network interface operations; no application role receives these permissions. See docs/security-exceptions.md.
  #checkov:skip=CKV_AWS_355:EC2 ENI discovery requires Resource wildcard; credential operations are ARN-scoped. See docs/security-exceptions.md.
  role   = aws_iam_role.credentials.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = concat([for d in aws_db_instance.this : d.master_user_secret[0].secret_arn], [for s in aws_secretsmanager_secret.runtime : s.arn], [for s in aws_secretsmanager_secret.migration : s.arn]) }, { Effect = "Allow", Action = ["secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"], Resource = concat([for s in aws_secretsmanager_secret.runtime : s.arn], [for s in aws_secretsmanager_secret.migration : s.arn]) }, { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.platform.arn }, { Effect = "Allow", Action = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"], Resource = "*" }, { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.credentials.arn}:*" }] })
}

resource "aws_iam_role_policy" "load-balancer" {
  role   = aws_iam_role.load-balancer.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ec2:DescribeInstances", "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeSecurityGroups", "ec2:DescribeNetworkInterfaces", "ec2:DescribeAvailabilityZones", "elasticloadbalancing:Describe*"], Resource = "*" }, { Effect = "Allow", Action = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"], Resource = [for t in aws_lb_target_group.service : t.arn] }] })
}

resource "aws_iam_role_policy" "telemetry" {
  role   = aws_iam_role.telemetry.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.apps.arn}:*" }, { Effect = "Allow", Action = "cloudwatch:PutMetricData", Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "Platform" } } }, { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"], Resource = "*" }] })
}

resource "aws_lambda_function" "credentials" {
  #checkov:skip=CKV_AWS_272:AWS Lambda code signing configuration does not support container images. Deploy verified digest-pinned ECR images. See docs/security-exceptions.md.
  kms_key_arn = aws_kms_key.platform.arn
  tracing_config { mode = "Active" }
  dead_letter_config { target_arn = aws_sqs_queue.rotation_dlq.arn }
  function_name                  = "${local.name}-credentials"
  role                           = aws_iam_role.credentials.arn
  package_type                   = "Image"
  image_uri                      = var.rotation_image_uri
  timeout                        = 300
  memory_size                    = 512
  reserved_concurrent_executions = 1
  vpc_config {
    subnet_ids         = module.network.application_subnets
    security_group_ids = [module.network.security_groups.nodes]
  }
  environment {
    variables = {
      "CONFIG" = jsonencode({ for k, v in var.services : k => { engine = v.engine, database = v.database.name, host = aws_db_instance.this[v.database_key].address, port = aws_db_instance.this[v.database_key].port, master = aws_db_instance.this[v.database_key].master_user_secret[0].secret_arn, runtime = aws_secretsmanager_secret.runtime[k].arn, migration = aws_secretsmanager_secret.migration[k].arn } })
    }
  }
  depends_on = [aws_iam_role_policy.credentials]
}

resource "aws_cloudwatch_event_rule" "rotation" {
  name                = "${local.name}-credential-rotation"
  schedule_expression = "rate(30 days)"
}

resource "aws_cloudwatch_event_rule" "interruptions" {
  name          = "${local.name}-interruptions"
  event_pattern = "{\"source\": [\"aws.ec2\", \"aws.health\"], \"detail-type\": [\"EC2 Spot Instance Interruption Warning\", \"EC2 Instance Rebalance Recommendation\", \"EC2 Instance State-change Notification\", \"AWS Health Event\"]}"
}

resource "aws_cloudwatch_event_target" "rotation" {
  rule  = aws_cloudwatch_event_rule.rotation.name
  arn   = aws_lambda_function.credentials.arn
  input = "{\"action\":\"rotate\"}"
  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }
}

resource "aws_cloudwatch_event_target" "interruptions" {
  rule = aws_cloudwatch_event_rule.interruptions.name
  arn  = aws_sqs_queue.interruptions.arn
}

resource "aws_lambda_permission" "rotation" {
  statement_id  = "ScheduledRotation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.credentials.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotation.arn
}

resource "aws_sqs_queue" "interruptions" {
  name                      = "${local.name}-interruptions"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "interruptions" {
  queue_url = aws_sqs_queue.interruptions.url
  policy    = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sqs:SendMessage", Resource = aws_sqs_queue.interruptions.arn, Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.interruptions.arn } } }, { Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.interruptions.arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}

# trivy:ignore:AVD-AWS-0053:exp:2027-01-16 -- Approved HTTPS edge with WAF; docs/security-exceptions.md.
resource "aws_lb" "api" {
  #checkov:skip=CKV2_AWS_76:Attached WebACL explicitly includes AWSManagedRulesKnownBadInputsRuleSet; graph resolution false positive, also checked by platform policy.
  name                       = "${local.name}-api"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [module.network.security_groups.alb]
  subnets                    = module.network.public_subnets
  enable_deletion_protection = true
  drop_invalid_header_fields = true
  access_logs {
    bucket  = aws_s3_bucket.access_logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.access_logs]
}

resource "aws_lb_target_group" "service" {
  for_each    = var.services
  name_prefix = "svc-"
  port        = 8443
  protocol    = "HTTPS"
  vpc_id      = module.network.vpc_id
  target_type = "ip"
  health_check {
    enabled  = true
    path     = "/actuator/health/readiness"
    protocol = "HTTPS"
    matcher  = "200"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "service" {
  for_each     = var.services
  listener_arn = aws_lb_listener.https.arn
  priority     = 100 + index(sort(keys(var.services)), each.key)
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }
  condition {
    host_header {
      values = ["${each.key}.${var.domain_name}"]
    }
  }
}

resource "aws_route53_record" "service" {
  for_each = var.services
  zone_id  = var.hosted_zone_id
  name     = "${each.key}.${var.domain_name}"
  type     = "A"
  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = true
  }
}

resource "aws_wafv2_web_acl" "api" {
  rule {
    name     = "aws-known-bad-inputs"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = false
    }
  }
  name  = local.name
  scope = "REGIONAL"
  default_action {
    allow {

    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = false
  }
  rule {
    name     = "aws-common"
    priority = 1
    override_action {
      none {

      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common"
      sampled_requests_enabled   = false
    }
  }
  rule {
    name     = "rate-limit"
    priority = 2
    action {
      block {

      }
    }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = false
    }
  }
}

resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_lb.api.arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "api" {
  resource_arn            = aws_wafv2_web_acl.api.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    query_string {

    }
  }
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.alerts.arn
}

resource "aws_sns_topic_subscription" "alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = local.name
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Environment$%s", var.environment)]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  for_each            = aws_db_instance.this
  alarm_name          = "${local.name}-${each.key}-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    "DBInstanceIdentifier" = each.value.identifier
  }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "missing"
}

resource "aws_cloudwatch_metric_alarm" "rotation_errors" {
  alarm_name          = "${local.name}-rotation-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    "FunctionName" = aws_lambda_function.credentials.function_name
  }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"
}

check "account_boundary" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.account_id && (local.production ? var.account_id == var.production_account_id : var.account_id != var.production_account_id)
    error_message = "Account mismatch or production account used by non-production."
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.name}-rds-monitoring"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "monitoring.rds.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:rds:${var.region}:${var.account_id}:db:${local.name}-*" } } }] })
}
resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
resource "aws_sqs_queue" "rotation_dlq" {
  name                      = "${local.name}-rotation-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}
resource "aws_iam_role_policy" "rotation_diagnostics" {
  role   = aws_iam_role.credentials.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.rotation_dlq.arn }, { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" }] })
}
resource "aws_cloudwatch_metric_alarm" "rotation_dlq" {
  alarm_name          = "${local.name}-rotation-dlq"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { QueueName = aws_sqs_queue.rotation_dlq.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
}
resource "aws_s3_bucket_logging" "service" {
  for_each      = aws_s3_bucket.service
  bucket        = each.value.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3/${each.key}/"
}

resource "aws_kms_key" "alerts" {
  description             = "Alarm delivery encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = "kms:*", Resource = "*" }, { Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = ["kms:Decrypt", "kms:GenerateDataKey*"], Resource = "*", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } }] })
}
resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = "SNS:*", Resource = aws_sns_topic.alerts.arn }, { Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "SNS:Publish", Resource = aws_sns_topic.alerts.arn, Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } }] })
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "${local.name}-api-target-errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
}
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each            = aws_lb_target_group.service
  alarm_name          = "${local.name}-${each.key}-unhealthy"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix, TargetGroup = each.value.arn_suffix }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
}
resource "aws_cloudwatch_metric_alarm" "db_storage" {
  for_each            = aws_db_instance.this
  alarm_name          = "${local.name}-${each.key}-free-storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5368709120
  comparison_operator = "LessThanThreshold"
  dimensions          = { DBInstanceIdentifier = each.value.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "missing"
}
resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  count               = local.cache_enabled ? 1 : 0
  alarm_name          = "${local.name}-cache-memory"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { CacheClusterId = "${aws_elasticache_replication_group.this[0].id}-001", CacheNodeId = "0001" }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "missing"
}

resource "aws_cloudwatch_log_group" "rds" {
  for_each = merge([for key, db in var.database_instances : {
    for log in(db.engine == "postgres" ? ["postgresql", "upgrade"] : ["error", "slowquery"]) : "${key}/${log}" => {
      instance = "${local.name}-${key}"
      log      = log
    }
  }]...)
  name              = "/aws/rds/instance/${each.value.instance}/${each.value.log}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.platform.arn
}
