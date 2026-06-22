resource "aws_db_subnet_group" "main" {
  name       = "fincorp-rds-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "fincorp-rds-subnet-group" }
}

resource "aws_db_instance" "postgres" {
  identifier        = var.db_identifier
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]

  multi_az               = false
  publicly_accessible    = false
  deletion_protection    = false
  skip_final_snapshot    = true

  backup_retention_period = 0

  tags = {
    Name        = var.db_identifier
    Environment = "primary"
    DR          = "true"
    ManagedBy   = "terraform"
  }
}
