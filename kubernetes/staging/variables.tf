variable "platform" {
  type        = object({ account_id = string, coredns_version = string, service_cidr = string, cluster_name = string, cluster_endpoint = string, cluster_ca = string, region = string, vpc_id = string, vpc_cidr = string, node_security_group = string, alb_security_group = string, instance_profile = string, interruption_queue = string, log_group = string, tags = map(string) })
  description = "Non-secret outputs from the infrastructure root."
}

variable "images" {
  type        = map(object({ repository = string, digest = string }))
  description = "Verified private ECR image repositories and sha256 digests for every controller."
}

variable "ami_id" {
  type        = string
  description = "Pinned EKS optimized AL2023 x86_64 AMI verified for region and EKS version."
}
