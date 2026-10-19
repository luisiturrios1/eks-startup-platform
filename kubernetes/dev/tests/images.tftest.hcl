mock_provider "helm" {}
mock_provider "aws" {}

variables {
  ami_id = "ami-00000000000000000"
  platform = {
    account_id         = "111111111111", coredns_version = "v1.12.0-eksbuild.1", service_cidr = "172.20.0.0/16",
    cluster_name       = "test", cluster_endpoint = "https://test.eks.amazonaws.com", cluster_ca = "dGVzdA==",
    region             = "us-east-1", vpc_id = "vpc-00000000", vpc_cidr = "10.40.0.0/16", node_security_group = "sg-00000000",
    alb_security_group = "sg-00000001", instance_profile = "test", interruption_queue = "test", log_group = "test", tags = {}
  }
  images = { for name in ["cert-manager", "cert-webhook", "cert-cainjector", "cert-startup", "karpenter", "load-balancer", "metrics", "otel", "fluent-bit"] : name => {
    repository = "111111111111.dkr.ecr.us-east-1.amazonaws.com/platform-artifacts"
    digest     = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  } }
  managed_addon_images = { for name in ["aws-node", "kube-proxy", "coredns", "eks-pod-identity-agent"] : name => [
    "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/${name}:v1.2.3-eksbuild.1"
  ] }
}

run "owned_images_and_scoped_exceptions" {
  command = plan
  assert {
    condition     = yamldecode(helm_release.guardrails.values[0]).registry == "111111111111.dkr.ecr.us-east-1.amazonaws.com"
    error_message = "Admission must bind to the exported environment account and region."
  }
  assert {
    condition = alltrue([for release in [helm_release.cert_manager, helm_release.karpenter, helm_release.load_balancer, helm_release.metrics, helm_release.platform] :
      release.postrender[0].args == tolist(["--registry", "111111111111.dkr.ecr.us-east-1.amazonaws.com"])
    ])
    error_message = "Every third-party/controller Helm release must use the environment registry post-renderer."
  }
}

run "foreign_helm_image" {
  command = plan
  variables {
    images = { for name, image in var.images : name => merge(image, {
      repository = "222222222222.dkr.ecr.us-east-1.amazonaws.com/foreign"
    }) }
  }
  expect_failures = [var.images]
}

run "foreign_region_helm_image" {
  command = plan
  variables {
    images = { for name, image in var.images : name => merge(image, {
      repository = "111111111111.dkr.ecr.us-west-2.amazonaws.com/foreign"
    }) }
  }
  expect_failures = [var.images]
}

run "unpinned_helm_image" {
  command = plan
  variables {
    images = { for name, image in var.images : name => merge(image, { digest = "latest" }) }
  }
  expect_failures = [var.images]
}

run "unscoped_managed_exception" {
  command = plan
  variables {
    managed_addon_images = { default = ["602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.2.3"] }
  }
  expect_failures = [var.managed_addon_images]
}
