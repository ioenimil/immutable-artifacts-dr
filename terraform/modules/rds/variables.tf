variable "db_identifier" {
  type    = string
  default = "fincorp-postgres"
}

variable "db_name" {
  type    = string
  default = "fincorp"
}

variable "db_username" {
  type      = string
  default   = "fincorp_admin"
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
  description = "Master password for the RDS instance — pass via TF_VAR or a secrets manager reference"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the RDS subnet group"
}

variable "rds_sg_id" {
  type        = string
  description = "Security group ID for RDS (from VPC module)"
}
