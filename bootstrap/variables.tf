variable "region" {
  type        = string
  description = "State region."
}

variable "account_id" {
  type        = string
  description = "Expected state account."
}

variable "bucket_name" {
  type        = string
  description = "Globally unique state bucket."
}

variable "owner" {
  type        = string
  description = "Owner."
}

variable "cost_center" {
  type        = string
  description = "Cost center."
}
