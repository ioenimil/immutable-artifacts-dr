variable "github_actions_role_arn" {
  type        = string
  description = "ARN of the GitHub Actions IAM role (needs GetAuthorizationToken)"
}

variable "ecs_task_role_arn" {
  type        = string
  description = "ARN of the ECS task IAM role (needs ReadFromRepository)"
}
