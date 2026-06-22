output "dev_repo_url" {
  value = aws_ecr_repository.repos["fincorp-api-dev"].repository_url
}

output "prod_repo_url" {
  value = aws_ecr_repository.repos["fincorp-api-prod"].repository_url
}

output "dev_repo_arn" {
  value = aws_ecr_repository.repos["fincorp-api-dev"].arn
}

output "prod_repo_arn" {
  value = aws_ecr_repository.repos["fincorp-api-prod"].arn
}
