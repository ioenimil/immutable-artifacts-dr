# FinCorp — Immutable & Indestructible Pipeline

Secure, auditable software supply chain for FinCorp with two independent workstreams:

- **Workstream A** — Immutable ECR artifact pipeline → ECS Fargate (eu-west-1)
- **Workstream B** — PostgreSQL RDS with cross-region DR backup (eu-west-1 → eu-central-1)

---

## Repository Structure

```
.
├── app/
│   ├── main.py             # FastAPI application
│   ├── requirements.txt    # Pinned Python dependencies
│   └── Dockerfile          # Multi-stage, non-root, no baked credentials
├── terraform/
│   ├── main.tf             # Root orchestrator
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf          # S3 state with native locking
│   ├── providers.tf        # eu-west-1 primary + eu-central-1 DR alias
│   └── modules/
│       ├── ecr/            # Two immutable ECR repos
│       ├── ecs/            # Fargate cluster, ALB, task def, service
│       ├── codeartifact/   # pip proxy (fincorp domain → pypi-store upstream)
│       ├── iam/            # OIDC provider, GitHub Actions role, ECS task roles
│       ├── vpc/            # VPC, subnets, SGs
│       ├── rds/            # PostgreSQL 16 (eu-west-1)
│       └── backup/         # AWS Backup plan + cross-region copy
├── .github/
│   └── workflows/
│       ├── ci.yml          # Build · Scan (CVE gate) · Push
│       └── deploy.yml      # Dev auto-deploy + prod manual approval
├── docs/
│   └── dr-runbook.md       # Step-by-step DR simulation runbook
├── bootstrap.sh            # One-time S3 state bucket creation
└── IMPLEMENTATION_PLAN.md  # Full task breakdown and agent assignment plan
```

---

## Prerequisites

| Tool | Min Version |
|------|-------------|
| AWS CLI | 2.x |
| Terraform | >= 1.10 (`use_lockfile = true` requires this) |
| Docker | 24.x |
| `jq` | 1.6+ |

AWS credentials must have permissions to create IAM roles, S3 buckets, ECR repos, ECS clusters, RDS instances, CodeArtifact domains, and AWS Backup plans.

---

## Setup

### 1 — Bootstrap Terraform state

Run once before `terraform init`:

```bash
export AWS_REGION=eu-west-1
./bootstrap.sh
```

The script prints the bucket name. Update `terraform/backend.tf`:
```hcl
bucket = "fincorp-tfstate-<your-account-id>"
```

### 2 — Configure GitHub repository

In your GitHub repository settings, create:

1. **Secret** `AWS_ROLE_ARN` — the ARN of the `github-actions-fincorp` IAM role (output of Terraform, available after step 3).
2. **Environment** `production` — add yourself as a required reviewer.

### 3 — Deploy infrastructure

```bash
cd terraform

terraform init

terraform apply \
  -var="github_org=<your-org>" \
  -var="github_repo=<your-repo>" \
  -var="tf_state_bucket_name=fincorp-tfstate-<account-id>" \
  -var="db_password=<strong-password>"
```

After apply, note the outputs:
```bash
terraform output
```

Copy `github_actions_role_arn` into the GitHub secret `AWS_ROLE_ARN`.

---

## Workstream A — Artifact Pipeline

### How it works

1. **Push to `main`** → triggers `ci.yml`
2. **CI** fetches a short-lived CodeArtifact pip token, builds the Docker image via CodeArtifact proxy (no credentials baked in), pushes to `fincorp-api-dev` ECR with tag = git SHA
3. **ECR scan** runs automatically on push; CI waits for completion
4. **CVE gate** — workflow fails if any `HIGH` or `CRITICAL` CVE is found; no deploy occurs
5. **deploy.yml** — triggered on CI success; updates ECS task definition with the new image; waits for service stability
6. **Production deploy** — manual `workflow_dispatch` with image SHA; requires reviewer approval via GitHub Environment

### Local smoke test

```bash
cd app
docker build --build-arg APP_VERSION=local-test -t fincorp-api:test .
docker run --rm -p 8080:8080 -e APP_VERSION=local-test fincorp-api:test
```

Then verify:
```bash
curl http://localhost:8080/
# {"status":"success","message":"FinCorp API is running"}

curl http://localhost:8080/healthz
# {"status":"healthy","version":"local-test"}
```

> **Note:** Local builds skip CodeArtifact (no `PIP_INDEX_URL` build-arg). PyPI is used directly. The CI build always routes through CodeArtifact.

### CVE gate test

To verify the gate blocks vulnerable images:
1. Temporarily change the base image in `app/Dockerfile` to an older version (e.g. `python:3.8-slim`)
2. Push to a test branch
3. Observe the CI workflow fail at the **CVE gate** step
4. Revert the base image change

---

## Workstream B — Disaster Recovery

### Normal state verification

```bash
# Confirm RDS is running in eu-west-1
aws rds describe-db-instances \
  --db-instance-identifier fincorp-postgres \
  --region eu-west-1 \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion}' \
  --output table

# Confirm backups are replicating to eu-central-1
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-dr-vault \
  --region eu-central-1 \
  --query 'RecoveryPoints[*].{Status:Status,Created:CreationDate}' \
  --output table
```

### DR simulation

Follow the step-by-step guide in [docs/dr-runbook.md](docs/dr-runbook.md).

**Target RTO: < 30 minutes** from deletion to restored instance `available`.

---

## Security notes

- **No long-lived AWS credentials** — GitHub Actions uses OIDC only; trust policy is scoped to the specific repo + `refs/heads/main`
- **ECR tag immutability** — once pushed, a SHA-tagged image cannot be overwritten
- **CVE gate** — High/Critical CVEs block promotion to any running environment
- **CodeArtifact** — all pip dependencies are proxied and auditable; external PyPI access is not required at container runtime
- **RDS encryption** — storage encrypted at rest with AWS-managed keys
- **Terraform state** — encrypted via SSE-S3, access controlled by IAM
