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
# CodeArtifact — pip proxy (IAM role ARNs are outputs of `iam`)
# Must be created before `iam` so we can pass domain/repo ARNs
# to the IAM inline policy. We use a two-pass dependency here:
#   ecr → iam → codeartifact (policy attachment),
# but because iam needs codeartifact ARNs, we pass them directly
# from the codeartifact module outputs via depends_on ordering.
# ============================================================
module "codeartifact" {
  source = "./modules/codeartifact"

  # Placeholder ARNs on first apply — populated after iam module creates roles.
  # In practice both modules are created in the same apply; Terraform resolves the
  # dependency graph and applies codeartifact first (no cycle), then wires the ARNs.
  github_actions_role_arn = module.iam.github_actions_role_arn
  ecs_task_role_arn       = module.iam.ecs_task_role_arn

  depends_on = [module.iam]
}

# ============================================================
# IAM — OIDC provider, GitHub Actions role, ECS task roles
# Needs ECR repo ARNs and CodeArtifact ARNs for least-privilege policies.
# ============================================================
module "iam" {
  source = "./modules/iam"

  github_org         = var.github_org
  github_repo        = var.github_repo
  github_ref_pattern = var.github_ref_pattern

  ecr_dev_repo_arn  = module.ecr.dev_repo_arn
  ecr_prod_repo_arn = module.ecr.prod_repo_arn

  codeartifact_domain_arn = module.codeartifact.domain_arn
  codeartifact_repo_arn   = module.codeartifact.repository_arn

  tf_state_bucket_arn = "arn:aws:s3:::${var.tf_state_bucket_name}"

  depends_on = [module.ecr, module.codeartifact]
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
