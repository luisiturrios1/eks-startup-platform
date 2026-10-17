output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr" {
  value = var.cidr
}

output "public_subnets" {
  value = [for s in aws_subnet.public : s.id]
}

output "application_subnets" {
  value = [for s in aws_subnet.application : s.id]
}

output "database_subnets" {
  value = [for s in aws_subnet.database : s.id]
}

output "security_groups" {
  value = { nodes = aws_security_group.nodes.id, api = aws_security_group.api.id, alb = aws_security_group.alb.id, database = aws_security_group.database.id, cache = aws_security_group.cache.id }
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
