output "backup_plan_id" {
  value = aws_backup_plan.daily.id
}

output "primary_vault_name" {
  value = aws_backup_vault.primary.name
}

output "dr_vault_name" {
  value = aws_backup_vault.dr.name
}

output "dr_vault_arn" {
  value = aws_backup_vault.dr.arn
}
