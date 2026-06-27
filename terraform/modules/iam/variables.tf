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

# CodeArtifact ARNs are constructed locally (see locals in main.tf) rather than
# consumed as module outputs — this breaks the iam <-> codeartifact dependency
# cycle. Only the deterministic names are needed.
variable "codeartifact_domain_name" {
  type        = string
  default     = "fincorp"
  description = "Name of the CodeArtifact domain (used to build its ARN)"
}

variable "codeartifact_repo_name" {
  type        = string
  default     = "fincorp-pip"
  description = "Name of the CodeArtifact pip repository (used to build its ARN)"
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
