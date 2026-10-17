locals {
  azs       = slice(data.aws_availability_zones.available.names, 0, 3)
  endpoints = ["ecr.api", "ecr.dkr", "ec2", "eks", "eks-auth", "sts", "secretsmanager", "kms", "logs", "monitoring", "xray", "ssm", "sqs", "elasticloadbalancing"]
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "zone-id"
    values = var.availability_zone_ids
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    "Name" = var.name
  }
}

resource "aws_default_security_group" "default" {
  vpc_id  = aws_vpc.this.id
  ingress = []
  egress  = []
  tags = {
    "Name" = "${var.name}-deny-default"
  }
}

resource "aws_internet_gateway" "public" {
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "public" {
  for_each                = { for i, az in local.azs : tostring(i) => az }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(var.cidr, 4, tonumber(each.key) + 0)
  map_public_ip_on_launch = false
  tags = {
    "Name"                   = "${var.name}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "application" {
  for_each                = { for i, az in local.azs : tostring(i) => az }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(var.cidr, 4, tonumber(each.key) + 3)
  map_public_ip_on_launch = false
  tags = {
    "Name"                   = "${var.name}-application-${each.key}"
    "karpenter.sh/discovery" = var.name
  }
}

resource "aws_subnet" "database" {
  for_each                = { for i, az in local.azs : tostring(i) => az }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(var.cidr, 4, tonumber(each.key) + 6)
  map_public_ip_on_launch = false
  tags = {
    "Name" = "${var.name}-database-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-public"
  }
}

resource "aws_route_table" "application" {
  vpc_id = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-application"
  }
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-database"
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "application" {
  for_each       = aws_subnet.application
  subnet_id      = each.value.id
  route_table_id = aws_route_table.application.id
}

resource "aws_route_table_association" "database" {
  for_each       = aws_subnet.database
  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.public.id
}

resource "aws_security_group" "nodes" {
  #checkov:skip=CKV2_AWS_5:Attached through networking module outputs to EKS, Lambda, ALB, RDS or ElastiCache; cross-module graph false positive.
  name_prefix = "${var.name}-nodes-"
  description = "nodes least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name"                   = "${var.name}-nodes"
    "karpenter.sh/discovery" = var.name
  }
}

resource "aws_security_group" "api" {
  #checkov:skip=CKV2_AWS_5:Attached through networking module outputs to EKS, Lambda, ALB, RDS or ElastiCache; cross-module graph false positive.
  name_prefix = "${var.name}-api-"
  description = "api least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-api"
  }
}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-endpoints-"
  description = "endpoints least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-endpoints"
  }
}

resource "aws_security_group" "vpn" {
  name_prefix = "${var.name}-vpn-"
  description = "vpn least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-vpn"
  }
}

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:Attached through networking module outputs to EKS, Lambda, ALB, RDS or ElastiCache; cross-module graph false positive.
  name_prefix = "${var.name}-alb-"
  description = "alb least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-alb"
  }
}

resource "aws_security_group" "database" {
  #checkov:skip=CKV2_AWS_5:Attached through networking module outputs to EKS, Lambda, ALB, RDS or ElastiCache; cross-module graph false positive.
  name_prefix = "${var.name}-database-"
  description = "database least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-database"
  }
}

resource "aws_security_group" "cache" {
  #checkov:skip=CKV2_AWS_5:Attached through networking module outputs to EKS, Lambda, ALB, RDS or ElastiCache; cross-module graph false positive.
  name_prefix = "${var.name}-cache-"
  description = "cache least privilege traffic boundary"
  vpc_id      = aws_vpc.this.id
  tags = {
    "Name" = "${var.name}-cache"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nodes_internal" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "nodes internal"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_nodes" {
  security_group_id            = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "api from nodes"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_vpn" {
  security_group_id            = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpn.id
  description                  = "api from vpn"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_api" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  referenced_security_group_id = aws_security_group.api.id
  description                  = "nodes from api"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_nodes" {
  security_group_id            = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "endpoints from nodes"
}

resource "aws_vpc_security_group_ingress_rule" "public_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "public https"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "nodes from alb"
}

resource "aws_vpc_security_group_ingress_rule" "db_3306" {
  security_group_id            = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "db 3306"
}

resource "aws_vpc_security_group_ingress_rule" "db_5432" {
  security_group_id            = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "db 5432"
}

resource "aws_vpc_security_group_ingress_rule" "cache" {
  security_group_id            = aws_security_group.cache.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "cache"
}

resource "aws_vpc_security_group_egress_rule" "nodes_internal_out" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "nodes internal out"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_api" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.api.id
  description                  = "nodes to api"
}

resource "aws_vpc_security_group_egress_rule" "vpn_to_api" {
  security_group_id            = aws_security_group.vpn.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.api.id
  description                  = "vpn to api"
}

resource "aws_vpc_security_group_egress_rule" "api_to_nodes" {
  security_group_id            = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "api to nodes"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_endpoints" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id
  description                  = "nodes to endpoints"
}

resource "aws_vpc_security_group_egress_rule" "nodes_dns_tcp" {
  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${cidrhost(var.cidr, 2)}/32"
  description       = "nodes dns tcp"
}

resource "aws_vpc_security_group_egress_rule" "vpn_dns_tcp" {
  security_group_id = aws_security_group.vpn.id
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${cidrhost(var.cidr, 2)}/32"
  description       = "vpn dns tcp"
}

resource "aws_vpc_security_group_egress_rule" "nodes_dns_udp" {
  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${cidrhost(var.cidr, 2)}/32"
  description       = "nodes dns udp"
}

resource "aws_vpc_security_group_egress_rule" "vpn_dns_udp" {
  security_group_id = aws_security_group.vpn.id
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${cidrhost(var.cidr, 2)}/32"
  description       = "vpn dns udp"
}

resource "aws_vpc_security_group_egress_rule" "alb_backend" {
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "alb backend"
}

resource "aws_vpc_security_group_egress_rule" "nodes_db_3306" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.database.id
  description                  = "nodes db 3306"
}

resource "aws_vpc_security_group_egress_rule" "nodes_db_5432" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.database.id
  description                  = "nodes db 5432"
}

resource "aws_vpc_security_group_egress_rule" "nodes_cache" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.cache.id
  description                  = "nodes cache"
}

resource "aws_vpc_security_group_egress_rule" "s3" {
  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  description       = "Private S3 gateway"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.application.id, aws_route_table.database.id]
  policy            = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = "*", Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"], Resource = "*", Condition = { StringEquals = { "aws:PrincipalAccount" = var.account_id } } }, { Effect = "Allow", Principal = "*", Action = "s3:GetObject", Resource = "arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*" }] })
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [for s in aws_subnet.application : s.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  policy              = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = "*", Action = "*", Resource = "*", Condition = { StringEquals = { "aws:PrincipalAccount" = var.account_id } } }] })
}

resource "aws_cloudwatch_log_group" "network" {
  name              = "/platform/${var.name}/network"
  retention_in_days = 365
  kms_key_id        = var.log_key_arn
}

resource "aws_iam_role" "flow" {
  name               = "${var.name}-flow-logs"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy" "flow" {
  role   = aws_iam_role.flow.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.network.arn}:*" }] })
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow.arn
  log_destination = aws_cloudwatch_log_group.network.arn
}

resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = var.name
  server_certificate_arn = var.vpn_server_certificate_arn
  client_cidr_block      = var.vpn_client_cidr
  split_tunnel           = true
  transport_protocol     = "udp"
  vpc_id                 = aws_vpc.this.id
  security_group_ids     = [aws_security_group.vpn.id]
  dns_servers            = [cidrhost(var.cidr, 2)]
  authentication_options {
    type              = "federated-authentication"
    saml_provider_arn = var.vpn_saml_provider_arn
  }
  connection_log_options {
    enabled              = true
    cloudwatch_log_group = aws_cloudwatch_log_group.network.name
  }
}

resource "aws_ec2_client_vpn_network_association" "this" {
  for_each               = aws_subnet.application
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = each.value.id
}

resource "aws_ec2_client_vpn_authorization_rule" "this" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = var.cidr
  access_group_id        = var.vpn_group
}

resource "aws_vpc_security_group_ingress_rule" "controller_webhook" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 9443
  to_port                      = 9443
  description                  = "EKS to load balancer admission webhook"
}
resource "aws_vpc_security_group_egress_rule" "controller_webhook" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 9443
  to_port                      = 9443
  description                  = "EKS to load balancer admission webhook"
}
