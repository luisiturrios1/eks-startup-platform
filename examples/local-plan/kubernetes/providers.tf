# This root can only use the explicitly named disposable kind context.
provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
    config_context = "kind-platform-review"
  }
}
