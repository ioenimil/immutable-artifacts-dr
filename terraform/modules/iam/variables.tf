variable "github_org" {
  type        = string
  description = "GitHub organisation name (e.g. my-org)"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name (e.g. fincorp-pipeline)"
}

variable "github_ref_pattern" {
  type        = string
  default     = "ref:refs/heads/main"
  description = "Ref pattern to scope the OIDC trust (e.g. ref:refs/heads/main)"
}

variable "codeartifact_domain_arn" {
  type        = string
  description = "ARN of the CodeArtifact domain (to scope GetAuthorizationToken)"
}

variable "codeartifact_repo_arn" {
  type        = string
  description = "ARN of the CodeArtifact pip repository"
}

variable "ecr_dev_repo_arn" {
  type        = string
  description = "ARN of the dev ECR repository"
}

variable "ecr_prod_repo_arn" {
  type        = string
  description = "ARN of the prod ECR repository"
}

variable "tf_state_bucket_arn" {
  type        = string
  description = "ARN of the S3 bucket holding Terraform state"
}
