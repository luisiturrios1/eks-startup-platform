variable "project_name" {
  type        = string
  description = "Short project identifier."
  default     = "startup"
}

variable "environment" {
  type        = string
  description = "Environment name."
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Use dev, staging or prod."
  }
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "account_id" {
  type        = string
  description = "Expected AWS account ID."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Provide a 12-digit account ID."
  }
}

variable "production_account_id" {
  type        = string
  description = "Dedicated production account ID."
}

variable "owner" {
  type        = string
  description = "Operational owner."
}

variable "cost_center" {
  type        = string
  description = "Cost allocation identifier."
}

variable "vpc_cidr" {
  type        = string
  description = "Private VPC CIDR."
}

variable "vpn_client_cidr" {
  type        = string
  description = "Non-overlapping VPN client CIDR."
}

variable "vpn_server_certificate_arn" {
  type        = string
  description = "Pre-issued ACM VPN certificate."
}

variable "vpn_saml_provider_arn" {
  type        = string
  description = "Existing SAML provider with MFA."
}

variable "vpn_group" {
  type        = string
  description = "Authorized administrator group."
}

variable "admin_role_arn" {
  type        = string
  description = "Federated operator role."
}

variable "certificate_arn" {
  type        = string
  description = "Regional ACM public HTTPS certificate."
}

variable "hosted_zone_id" {
  type        = string
  description = "Public Route53 zone."
}

variable "domain_name" {
  type        = string
  description = "API parent DNS domain."
}

variable "budget_usd" {
  type        = number
  description = "Approved monthly budget alert threshold."
}

variable "alert_email" {
  type        = string
  description = "Budget and alarm recipient."
}

variable "kubernetes_version" {
  type        = string
  description = "Supported EKS minor; verify region before deployment."
  default     = "1.35"
}

variable "system_instance_type" {
  type        = string
  description = "System node size."
  default     = "m7i.large"
}

variable "cache_node_type" {
  type        = string
  description = "Managed cache node size."
  default     = "cache.t4g.small"
}

variable "rotation_image_uri" {
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[^@]+@sha256:[a-f0-9]{64}$", var.rotation_image_uri))
    error_message = "Supply a private ECR credential manager image pinned by sha256 digest."
  }
  type        = string
  description = "Private ECR credential manager image pinned by digest."
}

variable "addons" {
  type        = map(string)
  description = "Region-compatible pinned EKS add-on versions; populated by preflight."
}

variable "services" {
  validation {
    condition     = alltrue(flatten([for service in var.services : [for arn in service.secretReferences : startswith(arn, "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.project_name}-${var.environment}/${service.name}/") && !strcontains(arn, "*") && !strcontains(arn, "/database/")]]))
    error_message = "Additional secret references must be exact ARNs under the owning service's environment/account prefix."
  }

  validation {
    condition     = alltrue([for service in var.services : can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[^@]+@sha256:[a-f0-9]{64}$", service.image)) && service.port == 8443 && service.scaling.minReplicas <= service.scaling.maxReplicas && (var.environment != "prod" || service.scaling.minReplicas >= 2)])
    error_message = "Deployments require private digest-pinned ECR images, port 8443, valid scaling bounds and at least two production replicas. Replace illustrative images before deployment."
  }
  type        = map(object({ apiVersion = string, secretReferences = optional(list(string), []), name = string, domain = string, image = string, port = number, resources = object({ requests = map(string), limits = map(string) }), scaling = object({ minReplicas = number, maxReplicas = number, cpuUtilization = number }), database = object({ placement = string, name = string, group = optional(string), engine = optional(string), engine_version = optional(string), instance_class = optional(string), storage_gb = optional(number) }), permissions = object({ s3 = list(string), cache = bool }), dependencies = list(string), migration = object({ command = list(string) }), database_key = string, engine = string }))
  description = "Compiled service contracts."
}

variable "database_instances" {
  type        = map(object({ domain = string, engine = string, engine_version = string, instance_class = string, storage_gb = number, multi_az = bool }))
  description = "Compiled RDS domain groups and dedicated instances."
  validation {
    condition     = alltrue([for d in var.database_instances : contains(["postgres", "mysql"], d.engine) && d.storage_gb >= 20])
    error_message = "RDS requires postgres/mysql and at least 20 GiB."
  }
}

variable "availability_zone_ids" {
  type        = list(string)
  description = "Three explicitly selected stable AZ IDs, verified in target region."
  validation {
    condition     = length(distinct(var.availability_zone_ids)) == 3
    error_message = "Select three distinct AZ IDs."
  }
}
