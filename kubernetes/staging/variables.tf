variable "platform" {
  type        = object({ account_id = string, coredns_version = string, service_cidr = string, cluster_name = string, cluster_endpoint = string, cluster_ca = string, region = string, vpc_id = string, vpc_cidr = string, node_security_group = string, alb_security_group = string, instance_profile = string, interruption_queue = string, log_group = string, tags = map(string) })
  description = "Non-secret outputs from the infrastructure root."
}

variable "images" {
  type        = map(object({ repository = string, digest = string }))
  description = "Verified ECR repositories in this environment account/region and sha256 digests for every controller."
  validation {
    condition = alltrue([for image in var.images :
      startswith(image.repository, "${var.platform.account_id}.dkr.ecr.${var.platform.region}.amazonaws.com/") &&
      can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9/_.-]+$", image.repository)) &&
      can(regex("^sha256:[a-f0-9]{64}$", image.digest))
    ])
    error_message = "All controller images must use the environment account/region ECR and an immutable sha256 digest."
  }
}

variable "ami_id" {
  type        = string
  description = "Pinned EKS optimized AL2023 x86_64 AMI verified for region and EKS version."
}

variable "managed_addon_images" {
  type        = map(list(string))
  description = "Reviewed exact AWS-managed image references, keyed by kube-system ServiceAccount. Refresh before any managed add-on upgrade."
  validation {
    condition = (
      toset(keys(var.managed_addon_images)) == toset(["aws-node", "kube-proxy", "coredns", "eks-pod-identity-agent"]) &&
      alltrue([for images in var.managed_addon_images : length(images) > 0 && alltrue([
        for image in images : can(regex("^[0-9]{12}\\.dkr\\.ecr\\.${var.platform.region}\\.amazonaws\\.com/[a-z0-9/_.-]+(:v[0-9][a-zA-Z0-9_.-]*|@sha256:[a-f0-9]{64})$", image))
      ])])
    )
    error_message = "Supply exact reviewed regional AWS ECR images for all four managed add-on ServiceAccounts; wildcards and public registries are forbidden."
  }
}

variable "service_namespaces" {
  type        = set(string)
  description = "Application namespaces exported from the validated service contracts. Existing namespaces require a reviewed ownership transition."
  default     = []
  validation {
    condition     = alltrue([for name in var.service_namespaces : can(regex("^[a-z][a-z0-9-]{2,30}$", name)) && !startswith(name, "kube-")])
    error_message = "Use service namespace names, excluding reserved Kubernetes namespaces."
  }
}
