#!/usr/bin/env bash
# One-time bootstrap: creates the S3 bucket used for Terraform state.
# Safe to re-run (idempotent). Requires AWS CLI and credentials with S3 permissions.
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="fincorp-tfstate-${ACCOUNT_ID}"

echo "==> Bootstrapping Terraform state bucket: ${BUCKET_NAME}"

# Create bucket (us-east-1 requires no LocationConstraint; all others require it)
if [ "${AWS_REGION}" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null || echo "    Bucket already exists, continuing."
else
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}" 2>/dev/null || echo "    Bucket already exists, continuing."
fi

echo "==> Enabling versioning"
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "==> Enabling SSE-S3 encryption"
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

echo "==> Blocking all public access"
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo ""
echo "==> Done. Terraform state bucket: ${BUCKET_NAME}"
echo "    Update terraform/backend.tf with: bucket = \"${BUCKET_NAME}\""
