# ---- Artifact Pipeline (Workstream A) ----

output "ecr_dev_repo_url" {
  value = module.ecr.dev_repo_url
}

output "ecr_prod_repo_url" {
  value = module.ecr.prod_repo_url
}

output "codeartifact_repository_endpoint" {
  value = module.codeartifact.repository_endpoint
}

output "codeartifact_domain_name" {
  value = module.codeartifact.domain_name
}

output "github_actions_role_arn" {
  value = module.iam.github_actions_role_arn
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "ecs_task_definition_family" {
  value = module.ecs.task_definition_family
}

output "alb_dns_name" {
  value = module.ecs.alb_dns_name
}

# ---- Disaster Recovery (Workstream B) ----

output "rds_endpoint" {
  value = module.rds.db_endpoint
}

output "rds_instance_id" {
  value = module.rds.db_instance_id
}

output "backup_plan_id" {
  value = module.backup.backup_plan_id
}

output "dr_vault_name" {
  value = module.backup.dr_vault_name
}
