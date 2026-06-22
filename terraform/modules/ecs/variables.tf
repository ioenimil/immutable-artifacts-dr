variable "environment" {
  type        = string
  description = "dev or prod"
}

variable "task_cpu" {
  type        = number
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
}

variable "task_memory" {
  type        = number
  description = "Fargate task memory in MiB"
}

variable "service_desired_count" {
  type        = number
  description = "Number of running tasks"
}

variable "ecr_repo_url" {
  type        = string
  description = "ECR repository URL for this environment"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the ALB"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for ECS tasks"
}

variable "alb_sg_id" {
  type = string
}

variable "ecs_sg_id" {
  type = string
}

variable "task_execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
