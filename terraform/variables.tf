variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment (dev | prod)"
}

variable "github_org" {
  type        = string
  description = "GitHub organisation name"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
}

variable "github_ref_pattern" {
  type    = string
  default = "ref:refs/heads/main"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "RDS master password — set via TF_VAR_db_password env var"
}

variable "tf_state_bucket_name" {
  type        = string
  description = "Name of the S3 bucket holding Terraform state (created by bootstrap.sh)"
}
