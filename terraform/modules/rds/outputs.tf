output "db_instance_id" {
  value = aws_db_instance.postgres.id
}

output "db_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_arn" {
  value = aws_db_instance.postgres.arn
}
