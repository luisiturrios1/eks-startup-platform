locals {
  contracts = jsondecode(file("../../../build/local-plan/contracts.json"))
}
resource "helm_release" "namespaces" {
  name      = "platform-service-namespaces"
  namespace = "kube-system"
  chart     = "../../../charts/namespaces"
  values    = [yamlencode({ namespaces = sort(keys(local.contracts.services)) })]
  wait      = true
  atomic    = true
  lifecycle { prevent_destroy = true }
}
