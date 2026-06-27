output "domain_name" {
  value = aws_codeartifact_domain.fincorp.domain
}

output "domain_arn" {
  value = aws_codeartifact_domain.fincorp.arn
}

output "repository_name" {
  value = aws_codeartifact_repository.fincorp_pip.repository
}

output "repository_arn" {
  value = aws_codeartifact_repository.fincorp_pip.arn
}

output "repository_endpoint" {
  value = data.aws_codeartifact_repository_endpoint.fincorp_pip.repository_endpoint
}
