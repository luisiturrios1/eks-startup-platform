variable "region" {
  type        = string
  description = "Commercial AWS region simulated by MiniStack."
  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "Use one of the two reviewed local region fixtures."
  }
}
variable "project_name" {
  type        = string
  description = "Region-qualified fixture name, including for globally named IAM and S3 resources."
  validation {
    condition     = var.project_name == "review-${var.region}"
    error_message = "Use the region-qualified review name to avoid global naming collisions."
  }
}
variable "availability_zone_ids" {
  type        = list(string)
  description = "Three AZ IDs supplied by the emulator in the selected region."
}
variable "vpc_cidr" {
  type        = string
  description = "Independent regional application network."
}
