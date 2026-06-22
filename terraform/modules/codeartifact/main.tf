data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_codeartifact_domain" "fincorp" {
  domain = "fincorp"
}

# Upstream connection to AWS-managed public PyPI proxy
resource "aws_codeartifact_repository" "pypi_store" {
  domain     = aws_codeartifact_domain.fincorp.domain
  repository = "pypi-store"

  external_connections {
    external_connection_name = "public:pypi"
  }
}

# fincorp-pip: internal repo that proxies through pypi-store
resource "aws_codeartifact_repository" "fincorp_pip" {
  domain     = aws_codeartifact_domain.fincorp.domain
  repository = "fincorp-pip"

  upstream {
    repository_name = aws_codeartifact_repository.pypi_store.repository
  }
}

# Resource-based policy on the domain: allow token fetch for CI + task roles
data "aws_iam_policy_document" "domain_policy" {
  statement {
    effect    = "Allow"
    actions   = ["codeartifact:GetAuthorizationToken"]
    principals {
      type        = "AWS"
      identifiers = [var.github_actions_role_arn]
    }
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["sts:GetServiceBearerToken"]
    principals {
      type        = "AWS"
      identifiers = [var.github_actions_role_arn]
    }
    resources = ["*"]
  }
}

resource "aws_codeartifact_domain_permissions_policy" "main" {
  domain          = aws_codeartifact_domain.fincorp.domain
  policy_document = data.aws_iam_policy_document.domain_policy.json
}

# Repository policy: allow CI + task roles to read
data "aws_iam_policy_document" "repo_policy" {
  statement {
    effect    = "Allow"
    actions   = [
      "codeartifact:ReadFromRepository",
      "codeartifact:GetRepositoryEndpoint",
      "codeartifact:DescribePackageVersion",
      "codeartifact:DescribeRepository",
      "codeartifact:GetPackageVersionReadme",
      "codeartifact:ListPackages",
      "codeartifact:ListPackageVersions",
    ]
    principals {
      type        = "AWS"
      identifiers = [var.github_actions_role_arn, var.ecs_task_role_arn]
    }
    resources = ["*"]
  }
}

resource "aws_codeartifact_repository_permissions_policy" "fincorp_pip" {
  domain          = aws_codeartifact_domain.fincorp.domain
  repository      = aws_codeartifact_repository.fincorp_pip.repository
  policy_document = data.aws_iam_policy_document.repo_policy.json
}
