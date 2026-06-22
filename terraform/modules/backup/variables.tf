variable "primary_retention_days" {
  type        = number
  default     = 7
  description = "Days to retain backups in the primary (eu-west-1) vault"
}

variable "dr_retention_days" {
  type        = number
  default     = 14
  description = "Days to retain backups in the DR (eu-central-1) vault"
}

variable "backup_schedule" {
  type        = string
  default     = "cron(0 2 * * ? *)"
  description = "Cron expression for daily backup (default: 02:00 UTC)"
}
