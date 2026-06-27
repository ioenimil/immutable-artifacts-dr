# The GitHub OIDC provider (https://token.actions.githubusercontent.com) is
# account-scoped — AWS allows exactly one per account. If it was created by a
# previous Terraform workspace or another project, CreateOpenIDConnectProvider
# returns EntityAlreadyExists (409). This import block adopts the pre-existing
# provider into state so Terraform manages it rather than trying to recreate it.
#
# Requires Terraform >= 1.5 (import blocks). This project requires >= 1.10.
# Safe to leave in place after first apply: if the resource is already in state,
# Terraform treats the import as a no-op on subsequent plans.

data "aws_caller_identity" "root" {}

import {
  to = module.iam.aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::${data.aws_caller_identity.root.account_id}:oidc-provider/token.actions.githubusercontent.com"
}
