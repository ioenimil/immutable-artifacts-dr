# Force Basic (Clair) scanning at the registry level so that scan_on_push
# triggers per-image scans and `aws ecr wait image-scan-complete` works in CI.
# Enhanced scanning (Inspector) supersedes this setting and breaks the wait command.
resource "aws_ecr_registry_scanning_configuration" "main" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

locals {
  repos = ["fincorp-api-dev", "fincorp-api-prod"]
}

resource "aws_ecr_repository" "repos" {
  for_each = toset(local.repos)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { ManagedBy = "terraform" }
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last ${var.keep_image_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_image_count
      }
      action = { type = "expire" }
    }]
  })
}
