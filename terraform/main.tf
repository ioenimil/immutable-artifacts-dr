# ============================================================
# ECR — standalone, no other module dependency
# ============================================================
module "ecr" {
  source = "./modules/ecr"
}

# ============================================================
# VPC — shared network foundation for ECS and RDS
# ============================================================
module "vpc" {
  source      = "./modules/vpc"
  environment = var.environment
}

# ============================================================
# IAM — OIDC provider, GitHub Actions role, ECS task roles
# Created before CodeArtifact: the CodeArtifact resource policies reference
# these role ARNs as principals, so the roles must exist first. IAM builds the
# CodeArtifact ARNs it needs locally (deterministic), so there is no cycle.
# ============================================================
module "iam" {
  source = "./modules/iam"

  github_org         = var.github_org
  github_repo        = var.github_repo
  github_ref_pattern = var.github_ref_pattern

  ecr_dev_repo_arn  = module.ecr.dev_repo_arn
  ecr_prod_repo_arn = module.ecr.prod_repo_arn

  tf_state_bucket_arn = "arn:aws:s3:::${var.tf_state_bucket_name}"
}

# ============================================================
# CodeArtifact — pip proxy. Its resource policies grant the IAM roles above
# (referenced via module.iam outputs), so it is applied after `iam`.
# ============================================================
module "codeartifact" {
  source = "./modules/codeartifact"

  github_actions_role_arn = module.iam.github_actions_role_arn
  ecs_task_role_arn       = module.iam.ecs_task_role_arn
}

# ============================================================
# ECS Fargate — cluster, ALB, task definition, service
# ============================================================
module "ecs" {
  source = "./modules/ecs"

  environment           = var.environment
  task_cpu              = var.environment == "prod" ? 512 : 256
  task_memory           = var.environment == "prod" ? 1024 : 512
  service_desired_count = var.environment == "prod" ? 2 : 1

  ecr_repo_url = var.environment == "prod" ? module.ecr.prod_repo_url : module.ecr.dev_repo_url

  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_sg_id          = module.vpc.alb_sg_id
  ecs_sg_id          = module.vpc.ecs_sg_id

  task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn           = module.iam.ecs_task_role_arn
  aws_region              = var.aws_region

  depends_on = [module.vpc, module.iam, module.ecr]
}

# ============================================================
# RDS — PostgreSQL 16 primary instance (Workstream B)
# ============================================================
module "rds" {
  source = "./modules/rds"

  private_subnet_ids = module.vpc.private_subnet_ids
  rds_sg_id          = module.vpc.rds_sg_id
  db_password        = var.db_password

  depends_on = [module.vpc]
}

# ============================================================
# Backup — daily snapshots + cross-region copy to eu-central-1
# ============================================================
module "backup" {
  source = "./modules/backup"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }
}
