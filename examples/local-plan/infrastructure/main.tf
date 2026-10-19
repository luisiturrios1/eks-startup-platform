locals {
  # The same schema/compiler and platform module as the AWS roots are exercised.
  contracts = jsondecode(file("../../../build/local-plan/contracts.json"))
  services = { for name, service in local.contracts.services : name => merge(service, {
    image = "000000000000.dkr.ecr.${var.region}.amazonaws.com/${name}@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }) }
}
module "platform" {
  source                     = "../../../modules/platform"
  project_name               = var.project_name
  environment                = "dev"
  region                     = var.region
  account_id                 = "000000000000"
  production_account_id      = "333333333333"
  owner                      = "platform-review"
  cost_center                = "local-evaluation"
  availability_zone_ids      = var.availability_zone_ids
  vpc_cidr                   = var.vpc_cidr
  vpn_client_cidr            = "10.250.0.0/22"
  vpn_server_certificate_arn = "arn:aws:acm:${var.region}:000000000000:certificate/00000000-0000-0000-0000-000000000001"
  certificate_arn            = "arn:aws:acm:${var.region}:000000000000:certificate/00000000-0000-0000-0000-000000000002"
  vpn_saml_provider_arn      = "arn:aws:iam::000000000000:saml-provider/local-review"
  vpn_group                  = "review-admins"
  admin_role_arn             = "arn:aws:iam::000000000000:role/local-review-admin"
  hosted_zone_id             = "Z0000000000000"
  domain_name                = "review.example.invalid"
  alert_email                = "review@example.invalid"
  budget_usd                 = 1000
  rotation_image_uri         = "000000000000.dkr.ecr.${var.region}.amazonaws.com/credential-manager@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # Schema-valid fixture versions, not a regional AWS compatibility claim.
  addons = {
    vpc-cni                = "v1.20.0-eksbuild.1"
    kube-proxy             = "v1.35.0-eksbuild.1"
    coredns                = "v1.12.0-eksbuild.1"
    eks-pod-identity-agent = "v1.3.0-eksbuild.1"
  }
  services           = local.services
  database_instances = local.contracts.database_instances
}
