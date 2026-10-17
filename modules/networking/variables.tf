variable "name" {
  type        = string
  description = "Resource name prefix."
}

variable "region" {
  type        = string
  description = "AWS region."
}

variable "cidr" {
  type        = string
  description = "VPC CIDR."
}

variable "account_id" {
  type        = string
  description = "Allowed AWS account."
}

variable "log_key_arn" {
  type        = string
  description = "CloudWatch log encryption key."
}

variable "vpn_server_certificate_arn" {
  type        = string
  description = "Existing ACM VPN server certificate."
}

variable "vpn_saml_provider_arn" {
  type        = string
  description = "Existing IAM SAML provider; MFA enforced by IdP."
}

variable "vpn_group" {
  type        = string
  description = "SAML administrator group."
}

variable "vpn_client_cidr" {
  type        = string
  description = "VPN client CIDR distinct from VPC and local networks."
}

variable "availability_zone_ids" {
  type        = list(string)
  description = "Three explicitly selected stable AZ IDs, verified in target region."
  validation {
    condition     = length(distinct(var.availability_zone_ids)) == 3
    error_message = "Select three distinct AZ IDs."
  }
}
