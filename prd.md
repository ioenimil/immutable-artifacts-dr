# PRD: "Immutable & Indestructible" Pipeline — FinCorp
**Version:** 1.0  
**Date:** 2026-06-22  
**Author:** Engineering  
**Status:** Ready for Task Breakdown

---

## 1. Overview

FinCorp requires a secure, auditable software supply chain backed by an immutable artifact pipeline and a cross-region disaster recovery strategy. This PRD covers two independent workstreams:

- **Workstream A — Artifact Pipeline:** A minimal FastAPI application built, scanned, and published through a fully automated GitHub Actions CI/CD pipeline using immutable ECR images and CodeArtifact as a pip proxy, deployed to ECS Fargate.
- **Workstream B — Disaster Recovery:** A standalone PostgreSQL RDS instance in `eu-west-1` (Ireland) with automated cross-region backup replication to `eu-central-1` (Frankfurt) and a documented DR failover simulation.

---

## 2. Goals & Non-Goals

### Goals
- Produce a container image pipeline where every image tag is immutable and scannable.
- Block builds automatically when High or Critical CVEs are found in the image.
- Use AWS CodeArtifact as an upstream pip proxy so all Python dependencies are auditable.
- Deploy the FastAPI app to ECS Fargate (dev auto-deploy, prod manual gate).
- Provide a cross-region RDS backup and a step-by-step DR runbook that achieves < 30-minute RTO.
- All infrastructure is managed via modular Terraform with S3 native state locking.
- GitHub Actions pipelines use OIDC authentication (no long-lived AWS keys).

### Non-Goals
- The FastAPI app does NOT connect to RDS — the two workstreams are independent.
- No custom domain or ACM certificate is in scope.
- No WAF, CloudFront, or API Gateway is in scope.
- No blue/green or canary deployment strategy.

---

## 3. Architecture Summary

### Workstream A — Artifact Pipeline

```
Developer Push (main branch)
        │
        ▼
GitHub Actions (OIDC → AWS)
        │
        ├─► CodeArtifact (pip proxy) ──► pip install during Docker build
        │
        ├─► docker build
        │
        ├─► ECR Image Scan (on push, Tag Immutability ON)
        │         └─ FAIL if High/Critical CVE found
        │
        └─► ECS Fargate (eu-west-1) ← dev auto-deploy
                                      prod = manual approval
```

**Regions:** eu-west-1 (Ireland) — primary for app workload  
**ECR Repos:** Two repos — `fincorp-api-dev` and `fincorp-api-prod` (one per environment)  
**Image Tags:** Git SHA (`git rev-parse --short HEAD`) — immutable, no `latest`

---

### Workstream B — Disaster Recovery

```
RDS PostgreSQL (eu-west-1) ── primary
        │
        ▼
AWS Backup Plan
        │── Daily snapshot (eu-west-1)
        └── Cross-Region Copy → eu-central-1 (Frankfurt)

DR Simulation:
  1. Delete primary RDS in eu-west-1
  2. Restore from backup in eu-central-1
  3. Validate connectivity
```

---

## 4. Application Specification (FastAPI)

### Structure
Single-file minimal FastAPI app (`main.py`) — no routers, no ORM.

### Endpoints

| Method | Path      | Response                                                     |
|--------|-----------|--------------------------------------------------------------|
| GET    | `/`       | `{"status": "success", "message": "FinCorp API is running"}` |
| GET    | `/healthz` | `{"status": "healthy", "version": "<GIT_SHA>"}`             |

### Runtime
- Python 3.12 slim base image
- Dependencies: `fastapi`, `uvicorn[standard]`
- Port: `8080`
- Environment variables: `APP_VERSION` (injected at build time via Docker ARG/ENV)

### Dockerfile Requirements
- Multi-stage build (builder + runtime)
- Non-root user
- pip install via CodeArtifact (token injected in CI, not baked into image)

---

## 5. Infrastructure Specification

### 5.1 Terraform Module Structure

```
terraform/
├── main.tf                  # Root orchestrator
├── variables.tf
├── outputs.tf
├── backend.tf               # S3 state, native locking
├── providers.tf             # AWS provider with alias for eu-central-1
└── modules/
    ├── ecr/                 # ECR repo, tag immutability, scan-on-push
    ├── ecs/                 # Fargate cluster, task def, service, ALB
    ├── codeartifact/        # Domain, repository, upstream PyPI
    ├── iam/                 # OIDC provider, GitHub Actions role, task roles
    ├── vpc/                 # VPC, subnets, SGs (reused across workstreams)
    ├── rds/                 # RDS PostgreSQL instance (eu-west-1)
    └── backup/              # AWS Backup plan, vault, cross-region copy
```

### 5.2 Terraform State Backend

```hcl
terraform {
  backend "s3" {
    bucket       = "fincorp-tfstate-<account_id>"
    key          = "fincorp/pipeline/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true   # S3 native locking (no DynamoDB required)
  }
}
```

### 5.3 ECR Module

- Two repositories: `fincorp-api-dev`, `fincorp-api-prod`
- `image_tag_mutability = "IMMUTABLE"`
- `scan_on_push = true`
- Lifecycle policy: keep last 10 images

### 5.4 ECS Fargate Module

- Cluster: `fincorp-cluster`
- Task: 0.25 vCPU / 0.5 GB RAM (dev), 0.5 vCPU / 1 GB RAM (prod)
- ALB with HTTP listener on port 80 → target group port 8080
- Service desired count: 1 (dev), 2 (prod)
- CloudWatch log group per environment

### 5.5 CodeArtifact Module

- Domain: `fincorp`
- Repository: `fincorp-pip`
- Upstream: `pypi-store` (public PyPI proxy)
- IAM policy: allow task role and GitHub Actions role to read

### 5.6 IAM / OIDC Module

- OIDC provider: `token.actions.githubusercontent.com`
- Role: `github-actions-fincorp` with trust policy scoped to the repo (e.g. `repo:your-org/fincorp-pipeline:ref:refs/heads/main`)
- Permissions: ECR push/pull, ECS update-service, CodeArtifact get-authorization-token, S3 state access

### 5.7 RDS Module (eu-west-1)

- Engine: PostgreSQL 16
- Instance: `db.t3.micro`
- Storage: 20 GB gp2, encrypted
- Multi-AZ: false (cost — DR is handled by backup)
- Deletion protection: false (required for DR simulation)
- Final snapshot: disabled (to allow clean delete in simulation)
- Tags: `Environment=primary`, `DR=true`

### 5.8 AWS Backup Module (eu-west-1 + eu-central-1)

- Backup vault: `fincorp-primary-vault` (eu-west-1)
- Backup vault: `fincorp-dr-vault` (eu-central-1)
- Backup plan: `fincorp-daily-backup`
  - Rule: daily at 02:00 UTC, 7-day retention in primary vault
  - Copy action: copy to `fincorp-dr-vault` in eu-central-1, 14-day retention
- Backup selection: tag-based (`DR=true`)
- IAM role: `AWSBackupDefaultServiceRole`

---

## 6. CI/CD Pipeline Specification (GitHub Actions)

### Repository Layout

```
.github/
└── workflows/
    ├── ci.yml          # Build, scan, push to ECR
    └── deploy.yml      # Deploy to ECS (dev auto, prod manual)
app/
├── main.py
├── requirements.txt
└── Dockerfile
terraform/
└── ...
```

### ci.yml — Build & Scan Workflow

**Trigger:** push to `main`  
**Auth:** OIDC (`aws-actions/configure-aws-credentials@v4`)

**Steps:**
1. Checkout code
2. Configure AWS credentials via OIDC
3. Fetch CodeArtifact pip token and set pip index URL
4. Log in to ECR (`aws-actions/amazon-ecr-login@v2`)
5. Build Docker image with `--build-arg APP_VERSION=${{ github.sha }}`
6. Push image to `fincorp-api-dev` ECR repo with tag = `${{ github.sha }}`
7. Wait for ECR image scan to complete (`aws ecr wait image-scan-complete`)
8. Check scan results — fail the job if any `HIGH` or `CRITICAL` findings exist
9. On success, output image URI as a job output for the deploy workflow

### deploy.yml — Deploy Workflow

**Trigger:** on completion of `ci.yml` (workflow_run)  
**Dev:** auto-deploy — update ECS service with new image  
**Prod:** `workflow_dispatch` with manual trigger + `environment: production` (requires GitHub environment approval)

**Steps:**
1. Configure AWS credentials via OIDC
2. Render new ECS task definition with updated image URI
3. Deploy to ECS Fargate service (`aws-actions/amazon-ecs-deploy-task-definition@v1`)
4. Wait for service stability

---

## 7. Disaster Recovery Runbook

### 7.1 Normal State
- Primary RDS running in `eu-west-1`
- Daily backups copying to `eu-central-1` vault automatically

### 7.2 DR Simulation Steps

**Step 1 — Simulate region failure**
```bash
aws rds delete-db-instance \
  --db-instance-identifier fincorp-postgres \
  --skip-final-snapshot \
  --region eu-west-1
```

**Step 2 — Identify recovery point in eu-central-1**
```bash
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-dr-vault \
  --region eu-central-1
```

**Step 3 — Restore from backup**
```bash
aws backup start-restore-job \
  --recovery-point-arn <arn-from-step-2> \
  --iam-role-arn arn:aws:iam::<account>:role/AWSBackupDefaultServiceRole \
  --region eu-central-1 \
  --metadata '{"DBInstanceIdentifier":"fincorp-postgres-dr","DBInstanceClass":"db.t3.micro","Engine":"postgres","MultiAZ":"false"}'
```

**Step 4 — Validate**
- Confirm RDS instance reaches `available` state in eu-central-1
- Record total elapsed time (target: < 30 minutes)
- Document endpoint and confirm PostgreSQL version

### 7.3 Recovery Time Objective
- Target RTO: **< 30 minutes** from deletion to restored DB available

---

## 8. Security Requirements

- No long-lived AWS credentials stored in GitHub Secrets — OIDC only
- ECR tag immutability prevents image overwrites
- Image scanning blocks any High/Critical CVE from reaching a running environment
- CodeArtifact creates an auditable, controlled pip dependency chain
- RDS storage encrypted at rest
- All Terraform state encrypted in S3 (SSE-S3)
- GitHub environment protection rules on `production`

---

## 9. Task Breakdown

### Epic 1 — Application

| # | Task | Notes |
|---|------|-------|
| 1.1 | Create FastAPI app (`main.py`) with `/` and `/healthz` endpoints | Returns JSON, version from env var |
| 1.2 | Write `requirements.txt` | `fastapi`, `uvicorn[standard]` |
| 1.3 | Write multi-stage `Dockerfile` | Non-root, port 8080, ARG for version |
| 1.4 | Local smoke test | `docker build && docker run` |

### Epic 2 — Terraform Foundation

| # | Task | Notes |
|---|------|-------|
| 2.1 | Create S3 bucket for Terraform state (bootstrap script) | `use_lockfile = true` |
| 2.2 | Write `backend.tf` and `providers.tf` (with eu-central-1 alias) | |
| 2.3 | Write `modules/vpc` | VPC, 2 public + 2 private subnets, IGW, NAT |
| 2.4 | Write `modules/iam` | OIDC provider, GitHub Actions role, ECS task roles |
| 2.5 | `terraform init && plan` on foundation | |

### Epic 3 — Artifact Pipeline Infrastructure

| # | Task | Notes |
|---|------|-------|
| 3.1 | Write `modules/ecr` | 2 repos, tag immutability, scan-on-push |
| 3.2 | Write `modules/codeartifact` | Domain, pip repo, PyPI upstream |
| 3.3 | Write `modules/ecs` | Fargate cluster, task def, service, ALB |
| 3.4 | Apply Terraform for dev environment | Verify all resources created |

### Epic 4 — GitHub Actions Pipeline

| # | Task | Notes |
|---|------|-------|
| 4.1 | Write `ci.yml` — OIDC auth, CodeArtifact token, build & push | |
| 4.2 | Add ECR scan wait + CVE gate step | Fail on High/Critical |
| 4.3 | Write `deploy.yml` — dev auto-deploy | ECS task def update |
| 4.4 | Add `production` environment + manual approval gate | GitHub Environments |
| 4.5 | End-to-end pipeline test — push to main, verify deploy | |
| 4.6 | Test CVE gate — introduce a vulnerable base image, verify failure | |

### Epic 5 — Disaster Recovery

| # | Task | Notes |
|---|------|-------|
| 5.1 | Write `modules/rds` | PostgreSQL 16, t3.micro, eu-west-1 |
| 5.2 | Write `modules/backup` | Primary vault, DR vault (eu-central-1), daily plan |
| 5.3 | Apply Terraform for RDS + Backup | Tag-based selection |
| 5.4 | Force immediate backup (for simulation readiness) | `aws backup start-backup-job` |
| 5.5 | Execute DR simulation — delete primary RDS | Document timestamp |
| 5.6 | Restore RDS in eu-central-1 from backup | Document elapsed time |
| 5.7 | Validate restored DB, record RTO | Must be < 30 min |

### Epic 6 — Documentation

| # | Task | Notes |
|---|------|-------|
| 6.1 | Architecture diagram (pipeline + DR) | Include in README |
| 6.2 | Pipeline walkthrough (screenshots/logs) | Build success + CVE failure |
| 6.3 | DR runbook — written, step-by-step | With timestamps from simulation |
| 6.4 | README — setup, how to run, how to demo | |
| 6.5 | Submission — live walkthrough preparation | Cover both workstreams |

---

## 10. Open Questions / Assumptions

| # | Item | Decision |
|---|------|----------|
| 1 | AWS account ID for OIDC trust policy | To be confirmed at setup time |
| 2 | GitHub org/repo name for OIDC scoping | To be confirmed |
| 3 | Terraform state S3 bucket bootstrap — manual or scripted? | Recommend a one-time `bootstrap.sh` |
| 4 | Prod ECS deploy — separate ECR image build or promote dev image? | Promote dev image (same SHA) to prod ECR repo |
| 5 | Backup: wait for first automated backup or force one manually? | Force manual backup immediately after RDS create for simulation | 