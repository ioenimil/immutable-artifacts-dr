terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.dr]
    }
  }
}

data "aws_caller_identity" "current" {}

# Primary vault in eu-west-1 (default provider)
resource "aws_backup_vault" "primary" {
  name = "fincorp-primary-vault"
  tags = { ManagedBy = "terraform" }
}

# DR vault in eu-central-1 (alias provider)
resource "aws_backup_vault" "dr" {
  provider = aws.dr
  name     = "fincorp-dr-vault"
  tags     = { ManagedBy = "terraform" }
}

resource "aws_backup_plan" "daily" {
  name = "fincorp-daily-backup"

  rule {
    rule_name         = "daily-at-0200-utc"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = var.backup_schedule
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.primary_retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = var.dr_retention_days
      }
    }
  }

  tags = { ManagedBy = "terraform" }
}

# Tag-based selection: backs up any resource tagged DR=true
resource "aws_backup_selection" "tagged" {
  name         = "fincorp-dr-tagged-resources"
  plan_id      = aws_backup_plan.daily.id
  iam_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/service-role/AWSBackupDefaultServiceRole"

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "DR"
    value = "true"
  }
}
