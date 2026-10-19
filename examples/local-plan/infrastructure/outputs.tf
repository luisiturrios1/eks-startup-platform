output "review" {
  description = "Non-secret regional identities used to inspect the plan."
  value = {
    region       = var.region
    cluster_name = module.platform.cluster_name
    namespaces   = sort(keys(local.services))
  }
}
