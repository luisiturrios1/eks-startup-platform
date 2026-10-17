output "cluster_name" {
  description = "cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "cluster endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  description = "cluster ca"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "region" {
  description = "region"
  value       = var.region
}

output "vpc_id" {
  description = "vpc id"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "vpc cidr"
  value       = var.vpc_cidr
}

output "node_security_group" {
  description = "node security group"
  value       = module.network.security_groups.nodes
}

output "alb_security_group" {
  description = "alb security group"
  value       = module.network.security_groups.alb
}

output "instance_profile" {
  description = "instance profile"
  value       = aws_iam_instance_profile.node.name
}

output "interruption_queue" {
  description = "interruption queue"
  value       = aws_sqs_queue.interruptions.name
}

output "credential_function" {
  description = "credential function"
  value       = aws_lambda_function.credentials.function_name
}

output "ecr_repositories" {
  description = "ecr repositories"
  value       = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}

output "log_group" {
  description = "log group"
  value       = aws_cloudwatch_log_group.apps.name
}

output "services" {
  description = "services"
  value       = { for k, v in var.services : k => merge(v, { secret_arn = aws_secretsmanager_secret.runtime[k].arn, migration_secret_arn = aws_secretsmanager_secret.migration[k].arn, target_group_arn = aws_lb_target_group.service[k].arn, bucket = try(aws_s3_bucket.service[k].id, ""), cache_host = aws_elasticache_replication_group.this.primary_endpoint_address, cache_user = try(aws_elasticache_user.service[k].user_name, ""), cache_resource = aws_elasticache_replication_group.this.id }) }
}

output "tags" {
  description = "Standard allocation and ownership tags for controller-created resources."
  value       = local.common_tags
}
