# No pods or admission webhooks are needed to install this bootstrap chart.
resource "helm_release" "network" {
  name             = "platform-network"
  namespace        = "cert-manager"
  create_namespace = true
  chart            = "../../charts/system-network"
  wait             = true
  atomic           = true
  values           = [yamlencode({ vpcCidr = var.platform.vpc_cidr, serviceCidr = var.platform.service_cidr, dnsResolver = cidrhost(var.platform.vpc_cidr, 2) })]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = var.platform.cluster_name
  addon_name                  = "coredns"
  addon_version               = var.platform.coredns_version
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [helm_release.network]
  lifecycle { prevent_destroy = true }
}

resource "helm_release" "cert_manager" {
  depends_on       = [aws_eks_addon.coredns]
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  chart            = "../../.artifacts/cert-manager-v1.21.2.tgz"
  wait             = true
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true
  values           = [yamlencode({ crds = { enabled = true }, image = { repository = var.images["cert-manager"].repository, digest = var.images["cert-manager"].digest }, webhook = { image = { repository = var.images["cert-webhook"].repository, digest = var.images["cert-webhook"].digest } }, cainjector = { image = { repository = var.images["cert-cainjector"].repository, digest = var.images["cert-cainjector"].digest } }, startupapicheck = { image = { repository = var.images["cert-startup"].repository, digest = var.images["cert-startup"].digest } } })]
  postrender {
    binary_path = "../../scripts/helm_postrender.py"
  }
}

resource "helm_release" "karpenter" {
  depends_on      = [aws_eks_addon.coredns]
  name            = "karpenter"
  namespace       = "kube-system"
  chart           = "../../.artifacts/karpenter-1.15.0.tgz"
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true
  values          = [yamlencode({ settings = { clusterName = var.platform.cluster_name, clusterEndpoint = var.platform.cluster_endpoint, interruptionQueue = var.platform.interruption_queue, isolatedVPC = true }, serviceAccount = { name = "karpenter" }, controller = { image = { repository = var.images["karpenter"].repository, digest = var.images["karpenter"].digest }, resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } } }, nodeSelector = { "platform/system" = "true" } })]
  postrender {
    binary_path = "../../scripts/helm_postrender.py"
  }
}

resource "helm_release" "load_balancer" {
  depends_on      = [aws_eks_addon.coredns]
  name            = "aws-load-balancer-controller"
  namespace       = "kube-system"
  chart           = "../../.artifacts/aws-load-balancer-controller-3.6.0.tgz"
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true
  values          = [yamlencode({ clusterName = var.platform.cluster_name, region = var.platform.region, vpcId = var.platform.vpc_id, serviceAccount = { name = "aws-load-balancer-controller" }, image = { repository = var.images["load-balancer"].repository, tag = "@${var.images["load-balancer"].digest}" }, enableShield = false, enableWaf = false, enableWafv2 = false, enableServiceMutatorWebhook = false, enableBackendSecurityGroup = false })]
  postrender {
    binary_path = "../../scripts/helm_postrender.py"
  }
}

resource "helm_release" "metrics" {
  depends_on      = [aws_eks_addon.coredns]
  name            = "metrics-server"
  namespace       = "kube-system"
  chart           = "../../.artifacts/metrics-server-3.13.0.tgz"
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true
  values          = [yamlencode({ image = { repository = var.images["metrics"].repository, tag = "@${var.images["metrics"].digest}" }, replicas = 2 })]
  postrender {
    binary_path = "../../scripts/helm_postrender.py"
  }
}

resource "helm_release" "platform" {
  name            = "platform"
  namespace       = "kube-system"
  chart           = "../../charts/platform"
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true
  values          = [yamlencode({ clusterName = var.platform.cluster_name, region = var.platform.region, instanceProfile = var.platform.instance_profile, nodeSecurityGroup = var.platform.node_security_group, vpcCidr = var.platform.vpc_cidr, serviceCidr = var.platform.service_cidr, amiId = var.ami_id, logGroup = var.platform.log_group, tags = var.platform.tags, images = { otel = "${var.images["otel"].repository}@${var.images["otel"].digest}", fluentBit = "${var.images["fluent-bit"].repository}@${var.images["fluent-bit"].digest}" } })]
  depends_on      = [helm_release.cert_manager, helm_release.karpenter, helm_release.load_balancer, helm_release.metrics]
  postrender {
    binary_path = "../../scripts/helm_postrender.py"
  }
}
