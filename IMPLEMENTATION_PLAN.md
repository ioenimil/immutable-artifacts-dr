# Implementation Plan — FinCorp Immutable & Indestructible Pipeline
**Generated:** 2026-06-22  
**Source:** prd.md v1.0  
**Strategy:** Maximum parallel execution via workstream isolation

---

## 1. PRD Summary

FinCorp requires a secure, auditable software supply chain with two independent workstreams:

| Workstream | Goal | Primary Region | Key Constraint |
|---|---|---|---|
| **A — Artifact Pipeline** | Immutable ECR images, CodeArtifact pip proxy, ECS Fargate deploy | eu-west-1 | No long-lived AWS credentials; CVE gate blocks High/Critical |
| **B — Disaster Recovery** | RDS PostgreSQL + cross-region backup replication to eu-central-1 | eu-west-1 → eu-central-1 | RTO < 30 minutes; DR simulation required |

**Shared Foundation:** Both workstreams share the same Terraform state backend, AWS provider config, VPC, and IAM/OIDC infrastructure.

---

## 2. Architecture & Component Analysis

### 2.1 Component Inventory

```
┌─────────────────────────────────────────────────────────────────────┐
│  SHARED FOUNDATION (blocks everything else)                         │
│  ┌──────────────┐  ┌─────────────────┐  ┌────────────────────────┐ │
│  │ S3 TF State  │  │ backend.tf +     │  │ modules/vpc            │ │
│  │ bootstrap.sh │  │ providers.tf     │  │ (VPC/subnets/SGs)      │ │
│  └──────────────┘  └─────────────────┘  └────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ modules/iam (OIDC provider, GitHub Actions role, task roles) │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
         │                                          │
         ▼                                          ▼
┌─────────────────────────┐            ┌─────────────────────────────┐
│  WORKSTREAM A           │            │  WORKSTREAM B               │
│  ┌───────────────────┐  │            │  ┌─────────────────────┐    │
│  │ FastAPI App       │  │            │  │ modules/rds          │    │
│  │ (main.py,         │  │            │  │ (PostgreSQL 16,      │    │
│  │  Dockerfile)      │  │            │  │  eu-west-1)          │    │
│  └───────────────────┘  │            │  └─────────────────────┘    │
│  ┌───────────────────┐  │            │  ┌─────────────────────┐    │
│  │ modules/ecr       │  │            │  │ modules/backup       │    │
│  │ (2 repos, immut.) │  │            │  │ (vaults, daily plan, │    │
│  └───────────────────┘  │            │  │  cross-region copy)  │    │
│  ┌───────────────────┐  │            │  └─────────────────────┘    │
│  │ modules/codeartif.│  │            │  ┌─────────────────────┐    │
│  │ (domain, pip repo)│  │            │  │ DR Simulation        │    │
│  └───────────────────┘  │            │  │ (delete → restore →  │    │
│  ┌───────────────────┐  │            │  │  validate)           │    │
│  │ modules/ecs       │  │            │  └─────────────────────┘    │
│  │ (Fargate, ALB)    │  │            └─────────────────────────────┘
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ GitHub Actions    │  │
│  │ (ci.yml,          │  │
│  │  deploy.yml)      │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

### 2.2 Terraform Module Dependency Map

```
bootstrap.sh (S3 bucket)
    └── backend.tf + providers.tf
            ├── modules/vpc
            │       ├── modules/rds      (needs subnet IDs, SG)
            │       └── modules/ecs      (needs subnet IDs, SG)
            ├── modules/iam
            │       ├── modules/codeartifact  (grants IAM roles access)
            │       └── modules/ecs           (grants task role)
            ├── modules/ecr              (standalone, just needs provider)
            ├── modules/codeartifact     (needs domain, IAM role ARN)
            └── modules/backup           (needs eu-central-1 provider alias)
```

### 2.3 Critical Path

```
bootstrap.sh → backend.tf → [vpc + iam] → [ecr + codeartifact + rds + ecs + backup]
    → ci.yml + deploy.yml → End-to-End Test → DR Simulation → Documentation
```

**Minimum sequential depth:** 5 layers. Everything within each layer is parallelizable.

---

## 3. Detailed Task Breakdown

### Epic 1 — Application (Workstream A)

---

#### Task 1.1 — FastAPI Application
- **Title:** Implement FastAPI app with health and root endpoints
- **Description:** Create `app/main.py` with two endpoints. Root endpoint returns static JSON. Healthz endpoint returns `{"status": "healthy", "version": "<GIT_SHA>"}` where version is read from the `APP_VERSION` environment variable (injected at build time).
- **Files:** `app/main.py`
- **Dependencies:** None
- **Complexity:** Small
- **Acceptance Criteria:**
  - `GET /` returns `{"status": "success", "message": "FinCorp API is running"}` with HTTP 200
  - `GET /healthz` returns `{"status": "healthy", "version": "<APP_VERSION env var>"}` with HTTP 200
  - App listens on port 8080
  - `uvicorn` is used as the ASGI server

---

#### Task 1.2 — Python Dependencies
- **Title:** Write `requirements.txt` with pinned versions
- **Description:** Declare `fastapi` and `uvicorn[standard]` with pinned versions for reproducibility. No other dependencies.
- **Files:** `app/requirements.txt`
- **Dependencies:** None
- **Complexity:** Small
- **Acceptance Criteria:**
  - File contains `fastapi==<version>` and `uvicorn[standard]==<version>`
  - Versions are compatible with Python 3.12

---

#### Task 1.3 — Multi-Stage Dockerfile
- **Title:** Write multi-stage Dockerfile for FastAPI app
- **Description:** Builder stage uses Python 3.12-slim to install dependencies via pip (pip index URL injected in CI, not baked in). Runtime stage is minimal Python 3.12-slim, copies only installed packages and app code. Creates a non-root user. Exposes port 8080. Accepts `APP_VERSION` as a build ARG and sets it as an ENV.
- **Files:** `app/Dockerfile`
- **Dependencies:** 1.1, 1.2
- **Complexity:** Small
- **Acceptance Criteria:**
  - Two stages: `builder` and `runtime`
  - Non-root user (`appuser` or similar) runs the process
  - `EXPOSE 8080`
  - `ARG APP_VERSION` and `ENV APP_VERSION=$APP_VERSION` present
  - No `pip` credentials or tokens baked into any layer
  - `docker build` succeeds locally with `--build-arg APP_VERSION=test`

---

#### Task 1.4 — Local Smoke Test
- **Title:** Validate Docker image builds and runs locally
- **Description:** Build the image locally and run it; verify both endpoints respond correctly. Document the exact commands in the README.
- **Files:** N/A (validation only); `README.md` (commands)
- **Dependencies:** 1.3
- **Complexity:** Small
- **Acceptance Criteria:**
  - `docker build` exits 0
  - `docker run -p 8080:8080 -e APP_VERSION=local-test ...` starts container
  - `curl http://localhost:8080/` returns expected JSON
  - `curl http://localhost:8080/healthz` returns expected JSON with `version: "local-test"`

---

### Epic 2 — Terraform Foundation

---

#### Task 2.1 — State Backend Bootstrap
- **Title:** Create S3 state bucket bootstrap script
- **Description:** Write `bootstrap.sh` that creates the S3 bucket `fincorp-tfstate-<account_id>` with versioning enabled, SSE-S3 encryption, and public access blocked. Must be idempotent (safe to re-run). This must be executed once before any `terraform init`.
- **Files:** `bootstrap.sh`
- **Dependencies:** None (AWS CLI prerequisite)
- **Complexity:** Small
- **Acceptance Criteria:**
  - Script is idempotent (no error on re-run)
  - Bucket has versioning enabled
  - Bucket has SSE-S3 encryption
  - Public access block is fully enabled
  - Script prints the bucket name at completion

---

#### Task 2.2 — Terraform Backend & Providers
- **Title:** Write `backend.tf` and `providers.tf`
- **Description:** Configure the S3 backend with `use_lockfile = true` (no DynamoDB). Define the primary AWS provider for `eu-west-1` and a provider alias `aws.dr` for `eu-central-1`. Used by the backup module for cross-region resources.
- **Files:** `terraform/backend.tf`, `terraform/providers.tf`
- **Dependencies:** 2.1
- **Complexity:** Small
- **Acceptance Criteria:**
  - `terraform init` succeeds after bootstrap
  - Backend block references `use_lockfile = true`
  - `eu-central-1` alias (`aws.dr`) is declared in providers.tf
  - No hardcoded account IDs or credentials

---

#### Task 2.3 — VPC Module
- **Title:** Write `modules/vpc` Terraform module
- **Description:** Creates a VPC with 2 public subnets and 2 private subnets across 2 AZs in eu-west-1. Includes Internet Gateway, NAT Gateway (single, in public subnet 1), and route tables. Security groups for ECS tasks (ingress from ALB) and RDS (ingress from ECS task SG). Outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `ecs_sg_id`, `rds_sg_id`.
- **Files:** `terraform/modules/vpc/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.2
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Module accepts `vpc_cidr`, `azs`, `environment` variables
  - NAT Gateway created in public subnet 1 only (cost-optimized)
  - ECS SG allows ingress on 8080 from ALB SG only
  - RDS SG allows ingress on 5432 from ECS task SG only
  - All outputs present and non-null after apply

---

#### Task 2.4 — IAM / OIDC Module
- **Title:** Write `modules/iam` Terraform module
- **Description:** Creates the GitHub Actions OIDC provider (`token.actions.githubusercontent.com`), a `github-actions-fincorp` role with trust policy scoped to the specific repo/ref, and an ECS task execution role. Attach managed policies for ECR push/pull, ECS update-service, CodeArtifact token fetch, and S3 state access. Outputs: `github_actions_role_arn`, `ecs_task_execution_role_arn`, `ecs_task_role_arn`.
- **Files:** `terraform/modules/iam/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.2
- **Complexity:** Medium
- **Acceptance Criteria:**
  - OIDC provider thumbprint is correct for GitHub Actions
  - Trust policy uses `StringLike` on `token.actions.githubusercontent.com:sub` scoped to repo + ref
  - GitHub Actions role has least-privilege permissions (no `*` wildcards on sensitive actions)
  - ECS task execution role can pull from ECR and write to CloudWatch Logs
  - Module accepts `github_org`, `github_repo`, `github_ref_pattern` as variables

---

#### Task 2.5 — Terraform Foundation Apply
- **Title:** Init, plan, and apply Terraform foundation
- **Description:** Run `terraform init`, `terraform plan`, and `terraform apply` for the foundation modules (VPC + IAM). Verify all outputs. Document any manual steps required (e.g., confirming OIDC provider ARN).
- **Files:** `terraform/main.tf` (root orchestrator referencing vpc and iam modules)
- **Dependencies:** 2.3, 2.4
- **Complexity:** Small
- **Acceptance Criteria:**
  - `terraform plan` shows 0 errors
  - `terraform apply` completes without errors
  - VPC and IAM outputs are correct and accessible
  - `terraform output` shows all expected values

---

### Epic 3 — Artifact Pipeline Infrastructure (Workstream A)

---

#### Task 3.1 — ECR Module
- **Title:** Write `modules/ecr` Terraform module
- **Description:** Creates two ECR repositories: `fincorp-api-dev` and `fincorp-api-prod`. Both have `image_tag_mutability = "IMMUTABLE"` and `scan_on_push = true`. Lifecycle policy keeps last 10 images. Outputs: `dev_repo_url`, `prod_repo_url`.
- **Files:** `terraform/modules/ecr/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.2
- **Complexity:** Small
- **Acceptance Criteria:**
  - Both repos have `IMMUTABLE` tag mutability
  - Both repos have `scan_on_push = true`
  - Lifecycle policy set to retain last 10 images
  - Repository URLs exported as outputs
  - Pushing the same tag twice fails (immutability confirmed)

---

#### Task 3.2 — CodeArtifact Module
- **Title:** Write `modules/codeartifact` Terraform module
- **Description:** Creates a CodeArtifact domain named `fincorp`, a repository `fincorp-pip` within that domain, and an upstream connection to `pypi-store` (AWS-managed public PyPI proxy). Attaches a resource policy allowing the GitHub Actions role and ECS task role to call `codeartifact:GetAuthorizationToken` and `codeartifact:ReadFromRepository`. Outputs: `domain_name`, `repository_name`, `repository_endpoint`.
- **Files:** `terraform/modules/codeartifact/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.2, 2.4
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Domain `fincorp` created
  - Repository `fincorp-pip` connected upstream to `pypi-store`
  - `aws codeartifact get-authorization-token` succeeds with GitHub Actions role
  - `pip install fastapi` resolves through CodeArtifact endpoint
  - Repository endpoint output is non-null

---

#### Task 3.3 — ECS Fargate Module
- **Title:** Write `modules/ecs` Terraform module
- **Description:** Creates an ECS cluster `fincorp-cluster`, ALB (with HTTP listener on port 80 → target group port 8080), a parameterized task definition (CPU/memory configurable per env), and an ECS service. CloudWatch log group per environment. Service desired count is a variable (1 for dev, 2 for prod). Task definition uses a placeholder image URI on first apply (updated by CI/CD thereafter). Outputs: `cluster_arn`, `service_name`, `alb_dns_name`, `task_definition_family`.
- **Files:** `terraform/modules/ecs/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.3, 2.4, 3.1
- **Complexity:** Large
- **Acceptance Criteria:**
  - ALB health check against `/healthz` returns healthy
  - Task definition CPU/memory are variables (dev: 256/512, prod: 512/1024)
  - CloudWatch log group created per environment
  - Service reaches `RUNNING` desired count after apply
  - ALB DNS name accessible on port 80

---

#### Task 3.4 — Apply Artifact Pipeline Terraform (Dev)
- **Title:** Apply ECR, CodeArtifact, and ECS modules for dev environment
- **Description:** Wire ECR, CodeArtifact, and ECS modules into the root `main.tf`, then apply for the dev environment. Verify all resources exist in the AWS console. Document outputs (repo URLs, ALB DNS, cluster name).
- **Files:** `terraform/main.tf`, `terraform/variables.tf`, `terraform/outputs.tf`
- **Dependencies:** 3.1, 3.2, 3.3, 2.5
- **Complexity:** Small
- **Acceptance Criteria:**
  - All 3 modules apply without errors
  - ECR repos visible in AWS console (eu-west-1)
  - CodeArtifact domain and pip repo created
  - ECS cluster and service created (may be in PENDING until first image pushed)
  - `terraform output` shows all values

---

### Epic 4 — GitHub Actions CI/CD Pipeline (Workstream A)

---

#### Task 4.1 — CI Workflow (Build & Push)
- **Title:** Write `ci.yml` GitHub Actions workflow
- **Description:** Triggers on push to `main`. Steps: checkout, configure AWS credentials via OIDC (`aws-actions/configure-aws-credentials@v4`), fetch CodeArtifact pip token and construct pip index URL, log in to ECR (`aws-actions/amazon-ecr-login@v2`), build Docker image with `--build-arg APP_VERSION=${{ github.sha }}`, push to `fincorp-api-dev` with tag `${{ github.sha }}`. Exports `image_uri` as a job output.
- **Files:** `.github/workflows/ci.yml`
- **Dependencies:** 2.4, 3.1, 3.2, 1.3
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Workflow triggers on push to `main`
  - No AWS credentials in any `env` or `secrets` (OIDC only)
  - Image tagged with `${{ github.sha }}` (short SHA)
  - CodeArtifact token is fetched at runtime and NOT embedded in the image
  - `image_uri` job output is set for downstream workflows

---

#### Task 4.2 — CVE Gate Step
- **Title:** Add ECR scan wait and CVE gate to `ci.yml`
- **Description:** After image push, add two steps: (1) `aws ecr wait image-scan-complete` for the pushed image, (2) parse scan findings JSON — if any `HIGH` or `CRITICAL` severity findings exist, fail the workflow with a descriptive error listing the CVE IDs. Workflow should succeed only if scan returns 0 High/Critical findings.
- **Files:** `.github/workflows/ci.yml`
- **Dependencies:** 4.1
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Step fails the job if `findingSeverityCounts.HIGH > 0` or `findingSeverityCounts.CRITICAL > 0`
  - Error message includes CVE count and severities
  - Step passes for a clean image
  - Entire workflow fails (not just the step) when CVEs are found

---

#### Task 4.3 — Deploy Workflow (Dev Auto-Deploy)
- **Title:** Write `deploy.yml` GitHub Actions workflow for dev auto-deploy
- **Description:** Triggers on completion of `ci.yml` (workflow_run event, conclusion: success). Configures AWS credentials via OIDC, downloads the task definition JSON from ECS, renders a new task definition with the new image URI (using `aws-actions/amazon-ecs-render-task-definition@v1`), deploys using `aws-actions/amazon-ecs-deploy-task-definition@v1`, and waits for service stability.
- **Files:** `.github/workflows/deploy.yml`
- **Dependencies:** 4.2, 3.3
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Workflow only runs when `ci.yml` succeeds
  - Dev deploy is fully automatic (no manual approval)
  - Task definition updated with new image URI
  - Workflow waits for ECS service to reach stable state
  - Deployment failure causes workflow failure

---

#### Task 4.4 — Production Manual Approval Gate
- **Title:** Add production environment with manual approval gate to `deploy.yml`
- **Description:** Add a separate `deploy-prod` job in `deploy.yml` that: (1) uses `environment: production` (triggers GitHub Environment protection rule requiring a reviewer), (2) is a `workflow_dispatch` trigger (or downstream of dev deploy success), (3) promotes the dev image (same SHA) to `fincorp-api-prod` ECR repo using `docker pull` + `docker tag` + `docker push`, (4) deploys to the prod ECS service.
- **Files:** `.github/workflows/deploy.yml`
- **Dependencies:** 4.3
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Production job requires a manual reviewer approval before running
  - GitHub `production` environment exists and has a required reviewer configured
  - Same image SHA promoted (no rebuild)
  - Prod ECS service updated to new task definition after approval
  - Prod service desired count is 2

---

#### Task 4.5 — End-to-End Pipeline Test
- **Title:** Run full pipeline end-to-end and validate
- **Description:** Push a commit to `main`, observe the full pipeline: CI builds, scans, pushes; deploy workflow triggers and updates ECS; ALB endpoint serves the new version. Capture screenshots/logs for documentation. Validate `/healthz` returns the pushed commit SHA.
- **Files:** N/A (validation); screenshots saved to `docs/screenshots/`
- **Dependencies:** 4.3, 3.4
- **Complexity:** Small
- **Acceptance Criteria:**
  - `ci.yml` completes green
  - `deploy.yml` (dev) completes green
  - `GET <ALB_DNS>/healthz` returns `{"status": "healthy", "version": "<github.sha>"}`
  - Total pipeline time documented

---

#### Task 4.6 — CVE Gate Failure Test
- **Title:** Validate CVE gate blocks a vulnerable image
- **Description:** Temporarily modify the Dockerfile to use an older, known-vulnerable base image (e.g., `python:3.8` or inject a package with known CVEs). Push to a test branch (or directly to a feature branch), observe that the CI workflow fails at the scan step. Screenshot the failure. Revert after validation.
- **Files:** `app/Dockerfile` (temporary change, then reverted)
- **Dependencies:** 4.2
- **Complexity:** Small
- **Acceptance Criteria:**
  - CI workflow fails at the CVE gate step (not at build or push)
  - Failure message names the severity and CVE count
  - No deployment occurs when CVE gate fails
  - Base image is reverted to `python:3.12-slim` after test

---

### Epic 5 — Disaster Recovery (Workstream B)

---

#### Task 5.1 — RDS Module
- **Title:** Write `modules/rds` Terraform module
- **Description:** Creates a PostgreSQL 16 RDS instance (`fincorp-postgres`) in eu-west-1. `db.t3.micro`, 20 GB gp2 storage, encrypted at rest. Multi-AZ false. Deletion protection false (required for DR simulation). Final snapshot disabled (`skip_final_snapshot = true`). Tags: `Environment=primary`, `DR=true`. Places instance in private subnets with the RDS security group. Outputs: `db_instance_id`, `db_endpoint`, `db_port`.
- **Files:** `terraform/modules/rds/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.3
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Instance identifier is `fincorp-postgres`
  - Engine is `postgres`, major version 16
  - Storage encrypted (`storage_encrypted = true`)
  - Tags `DR=true` and `Environment=primary` present
  - `deletion_protection = false`
  - `skip_final_snapshot = true`
  - Instance endpoint exported as output

---

#### Task 5.2 — AWS Backup Module
- **Title:** Write `modules/backup` Terraform module
- **Description:** Creates two backup vaults: `fincorp-primary-vault` (eu-west-1, default provider) and `fincorp-dr-vault` (eu-central-1, `aws.dr` provider alias). Creates a backup plan `fincorp-daily-backup` with a daily rule at 02:00 UTC, 7-day retention in primary vault, and a copy action to `fincorp-dr-vault` with 14-day retention. Creates a backup selection using tag-based selection (`DR=true`). Uses `AWSBackupDefaultServiceRole`. Outputs: `backup_plan_id`, `primary_vault_name`, `dr_vault_name`.
- **Files:** `terraform/modules/backup/main.tf`, `variables.tf`, `outputs.tf`
- **Dependencies:** 2.2
- **Complexity:** Medium
- **Acceptance Criteria:**
  - Primary vault created in eu-west-1
  - DR vault created in eu-central-1 (using `aws.dr` provider alias)
  - Backup plan runs at 02:00 UTC daily
  - Primary vault retention: 7 days
  - DR vault retention: 14 days
  - Tag-based selection selects resources tagged `DR=true`
  - `AWSBackupDefaultServiceRole` is used (not a custom role)

---

#### Task 5.3 — Apply RDS and Backup Terraform
- **Title:** Apply RDS and Backup modules
- **Description:** Wire RDS and Backup modules into root `main.tf`, then apply. Verify RDS reaches `available` state and backup selection is active. Confirm tag `DR=true` on the RDS instance is picked up by the backup selection.
- **Files:** `terraform/main.tf`
- **Dependencies:** 5.1, 5.2, 2.5
- **Complexity:** Small
- **Acceptance Criteria:**
  - RDS instance reaches `available` state
  - Backup plan is active
  - Backup selection identifies the RDS instance
  - `terraform output` shows RDS endpoint and backup plan ID

---

#### Task 5.4 — Force Immediate Backup
- **Title:** Trigger manual backup for DR simulation readiness
- **Description:** Immediately after RDS is available, trigger a manual backup job using `aws backup start-backup-job` targeting the RDS instance. Wait for the job to complete successfully and for the recovery point to appear in the primary vault. Then verify the cross-region copy appears in `fincorp-dr-vault` in eu-central-1.
- **Files:** `docs/dr-runbook.md` (add this step and its output)
- **Dependencies:** 5.3
- **Complexity:** Small
- **Acceptance Criteria:**
  - Manual backup job completes with status `COMPLETED`
  - Recovery point ARN is available in `fincorp-primary-vault` (eu-west-1)
  - Cross-region copy recovery point appears in `fincorp-dr-vault` (eu-central-1)
  - Recovery point ARN from eu-central-1 is recorded (needed for 5.6)

---

#### Task 5.5 — DR Simulation: Delete Primary RDS
- **Title:** Execute DR simulation step 1 — simulate region failure
- **Description:** Record the timestamp, then delete the primary RDS instance in eu-west-1 using `aws rds delete-db-instance --skip-final-snapshot`. Wait for deletion to complete. Confirm instance no longer appears in `aws rds describe-db-instances`.
- **Files:** `docs/dr-runbook.md` (document timestamp + output)
- **Dependencies:** 5.4
- **Complexity:** Small
- **Acceptance Criteria:**
  - Deletion timestamp recorded
  - RDS instance status transitions to `deleting` then disappears
  - No final snapshot created (matches `skip_final_snapshot = true`)

---

#### Task 5.6 — DR Simulation: Restore in eu-central-1
- **Title:** Execute DR simulation step 2 & 3 — restore from backup
- **Description:** List recovery points in `fincorp-dr-vault` (eu-central-1), identify the latest one, and start a restore job using `aws backup start-restore-job`. Metadata: `DBInstanceIdentifier=fincorp-postgres-dr`, `DBInstanceClass=db.t3.micro`, `Engine=postgres`, `MultiAZ=false`. Monitor restore job until status is `COMPLETED`.
- **Files:** `docs/dr-runbook.md` (document recovery point ARN + restore job output)
- **Dependencies:** 5.5
- **Complexity:** Small
- **Acceptance Criteria:**
  - Restore job initiated with correct metadata
  - Restore job status reaches `COMPLETED`
  - New RDS instance `fincorp-postgres-dr` exists in eu-central-1

---

#### Task 5.7 — DR Simulation: Validate and Record RTO
- **Title:** Validate restored DB and record RTO
- **Description:** Confirm the restored RDS instance in eu-central-1 reaches `available` state. Record the PostgreSQL version (confirm it is v16). Calculate total elapsed time from deletion (5.5 timestamp) to `available` state. RTO must be < 30 minutes.
- **Files:** `docs/dr-runbook.md` (complete with timestamps, endpoint, RTO)
- **Dependencies:** 5.6
- **Complexity:** Small
- **Acceptance Criteria:**
  - Instance `fincorp-postgres-dr` is in `available` state in eu-central-1
  - PostgreSQL version confirmed as 16.x
  - Total elapsed time from deletion to available < 30 minutes
  - All commands, timestamps, and outputs documented in runbook

---

### Epic 6 — Documentation

---

#### Task 6.1 — Architecture Diagram
- **Title:** Create architecture diagrams for both workstreams
- **Description:** ASCII or rendered diagram showing: (A) the full CI/CD pipeline flow from git push to ECS deploy via ECR + CodeArtifact, and (B) the DR architecture showing primary RDS in eu-west-1, backup vaults, and cross-region copy to eu-central-1.
- **Files:** `docs/architecture.md` or embedded in `README.md`
- **Dependencies:** 3.4 (for accurate resource names) — can be drafted earlier
- **Complexity:** Small
- **Acceptance Criteria:**
  - Both workstreams diagrammed
  - All components and data flows labeled
  - Regions clearly marked
  - Diagrams are accurate to the deployed state

---

#### Task 6.2 — Pipeline Walkthrough with Evidence
- **Title:** Document pipeline run with screenshots/logs
- **Description:** Capture and annotate: (1) a successful pipeline run (green CI + green deploy, ALB endpoint showing correct SHA), and (2) a CVE gate failure (red CI at scan step with CVE details). Include log excerpts or GitHub Actions screenshots.
- **Files:** `docs/pipeline-walkthrough.md`, `docs/screenshots/`
- **Dependencies:** 4.5, 4.6
- **Complexity:** Small
- **Acceptance Criteria:**
  - Successful pipeline run documented with timestamps
  - CVE failure screenshot shows the specific step and error
  - ALB endpoint response from `/healthz` included

---

#### Task 6.3 — DR Runbook
- **Title:** Finalize the DR runbook with simulation timestamps
- **Description:** Write a complete, step-by-step DR runbook in `docs/dr-runbook.md` that a new engineer could follow to execute a failover. Include: prerequisites, exact AWS CLI commands (with real ARNs from the simulation), expected outputs at each step, observed timestamps from the actual simulation, and the measured RTO.
- **Files:** `docs/dr-runbook.md`
- **Dependencies:** 5.7
- **Complexity:** Medium
- **Acceptance Criteria:**
  - All 4 simulation steps documented with real command output
  - Timestamps present (start of deletion, restore job start, instance available)
  - Measured RTO stated explicitly (must be < 30 min)
  - Runbook is self-contained (no external references required)

---

#### Task 6.4 — README
- **Title:** Write top-level README
- **Description:** Cover: project overview, repository structure, prerequisites (AWS CLI, Terraform, Docker), how to bootstrap (run `bootstrap.sh`), how to deploy infrastructure (`terraform apply`), how to trigger the pipeline, how to run the DR simulation, and how to demo the solution.
- **Files:** `README.md`
- **Dependencies:** 6.1, 6.3 (for links); can draft earlier
- **Complexity:** Small
- **Acceptance Criteria:**
  - Someone unfamiliar with the project can set it up from scratch using only the README
  - All prerequisites listed
  - Bootstrap and deploy steps accurate
  - Links to `docs/` files for detailed runbooks

---

#### Task 6.5 — Demo Preparation
- **Title:** Prepare live walkthrough demonstration
- **Description:** Create a concise demo script covering both workstreams. Workstream A: show a git push triggering the pipeline, CVE gate in action, and the ALB serving the new version. Workstream B: show the backup plan in the AWS console, walk through the DR runbook, show the restored instance. Prepare talking points and expected durations.
- **Files:** `docs/demo-script.md`
- **Dependencies:** 6.2, 6.3, 6.4
- **Complexity:** Small
- **Acceptance Criteria:**
  - Demo script covers both workstreams
  - Demo is runnable end-to-end in < 20 minutes
  - Talking points for each decision (OIDC, immutable tags, CodeArtifact, RTO) included

---

## 4. Dependency Graph

```
Layer 0 (No dependencies — start immediately in parallel):
  [1.1] FastAPI main.py
  [1.2] requirements.txt
  [2.1] bootstrap.sh (S3 bucket)

Layer 1 (Unblocked after Layer 0):
  [1.3] Dockerfile           ← needs 1.1, 1.2
  [2.2] backend.tf + providers.tf  ← needs 2.1

Layer 2 (Unblocked after Layer 1):
  [1.4] Local smoke test     ← needs 1.3
  [2.3] modules/vpc          ← needs 2.2
  [2.4] modules/iam          ← needs 2.2
  [3.1] modules/ecr          ← needs 2.2
  [5.2] modules/backup       ← needs 2.2

Layer 3 (Unblocked after Layer 2):
  [2.5] TF foundation apply  ← needs 2.3, 2.4
  [3.2] modules/codeartifact ← needs 2.4
  [5.1] modules/rds          ← needs 2.3

Layer 4 (Unblocked after Layer 3):
  [3.3] modules/ecs          ← needs 2.3, 2.4, 3.1
  [3.4] Apply pipeline TF    ← needs 3.1, 3.2, 3.3, 2.5
  [5.3] Apply RDS + Backup   ← needs 5.1, 5.2, 2.5

Layer 5 (Unblocked after Layer 4):
  [4.1] ci.yml               ← needs 2.4, 3.1, 3.2, 1.3
  [4.2] CVE gate             ← needs 4.1
  [5.4] Force backup         ← needs 5.3

Layer 6 (Unblocked after Layer 5):
  [4.3] deploy.yml (dev)     ← needs 4.2, 3.3
  [5.5] DR delete RDS        ← needs 5.4

Layer 7 (Unblocked after Layer 6):
  [4.4] Prod approval gate   ← needs 4.3
  [5.6] DR restore           ← needs 5.5

Layer 8 (Unblocked after Layer 7):
  [4.5] E2E pipeline test    ← needs 4.3, 3.4
  [4.6] CVE gate test        ← needs 4.2
  [5.7] Validate RTO         ← needs 5.6

Layer 9 (Documentation — finalizes after Layer 8):
  [6.1] Architecture diagram ← can draft from Layer 4; finalize after Layer 8
  [6.2] Pipeline walkthrough ← needs 4.5, 4.6
  [6.3] DR runbook           ← needs 5.7
  [6.4] README               ← needs 6.1, 6.3
  [6.5] Demo preparation     ← needs 6.2, 6.3, 6.4
```

**Critical Path (longest dependency chain):**
```
2.1 → 2.2 → 2.3 → 2.5 → 3.3 → 3.4 → 4.1 → 4.2 → 4.3 → 4.5 → 6.2 → 6.4 → 6.5
```
(13 sequential steps — all other work is parallelizable within this timeline)

---

## 5. Agent Assignment Plan

### Agent Alpha — Application Engineer

**Role:** Owns all application code. Parallel to everything else.

**Assigned Tasks:** 1.1, 1.2, 1.3, 1.4

**Expected Outputs:**
- `app/main.py` — FastAPI app with `/` and `/healthz`
- `app/requirements.txt` — pinned `fastapi` and `uvicorn[standard]`
- `app/Dockerfile` — multi-stage, non-root, ARG APP_VERSION
- Validation: local `docker build` + `docker run` succeeds

**Interfaces / Contracts with Other Agents:**
- **Provides to Agent Charlie (CI/CD):** `app/Dockerfile` path and build args contract (`--build-arg APP_VERSION=<sha>`)
- **Provides to Agent Charlie:** `requirements.txt` (determines which packages flow through CodeArtifact)
- **Contract:** Dockerfile MUST NOT include pip credentials; pip index URL is injected via `--build-arg` or build-time environment only

**Coordination:** None required. Starts immediately in Layer 0.

---

### Agent Beta — Terraform Foundation Engineer

**Role:** Owns all shared Terraform infrastructure. Blocks Agents Delta and Epsilon.

**Assigned Tasks:** 2.1, 2.2, 2.3, 2.4, 2.5

**Expected Outputs:**
- `bootstrap.sh` — idempotent S3 bucket creation
- `terraform/backend.tf`, `terraform/providers.tf`
- `terraform/modules/vpc/` — complete VPC module with outputs
- `terraform/modules/iam/` — OIDC + GitHub Actions + ECS task roles
- `terraform/main.tf` (root — foundation modules wired)
- Terraform apply: VPC and IAM resources provisioned in eu-west-1

**Interfaces / Contracts with Other Agents:**
- **Provides to Agent Delta:** `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `ecs_sg_id`, `rds_sg_id` as TF outputs
- **Provides to Agent Delta:** `github_actions_role_arn`, `ecs_task_execution_role_arn`, `ecs_task_role_arn` as TF outputs
- **Provides to Agent Epsilon:** `vpc_id`, `private_subnet_ids`, `rds_sg_id`, `aws.dr` provider alias
- **Provides to Agent Charlie:** OIDC role ARN (needed in `ci.yml` `role-to-assume` field)
- **Contract:** All TF modules must accept variables from root `main.tf`; no hardcoded values inside modules

**Coordination:**
- Must share `terraform output` values with Agents Delta and Epsilon before they begin Apply tasks (3.4, 5.3)
- Shared `terraform/main.tf` — coordinate module additions with Delta and Epsilon to avoid conflicts

---

### Agent Delta — Pipeline Infrastructure Engineer

**Role:** Owns ECR, CodeArtifact, and ECS Fargate Terraform modules. Unblocked after Beta's foundation.

**Assigned Tasks:** 3.1, 3.2, 3.3, 3.4

**Expected Outputs:**
- `terraform/modules/ecr/` — two immutable repos with lifecycle policy
- `terraform/modules/codeartifact/` — domain, pip repo, PyPI upstream
- `terraform/modules/ecs/` — Fargate cluster, ALB, task def, service
- Dev environment applied: ECR repos, CodeArtifact, ECS cluster all provisioned

**Interfaces / Contracts with Other Agents:**
- **Requires from Agent Beta:** VPC outputs (subnets, SGs), IAM role ARNs
- **Provides to Agent Charlie:** `dev_repo_url`, `prod_repo_url` (ECR), `repository_endpoint` (CodeArtifact), `cluster_name`, `service_name`, `task_definition_family` (ECS)
- **Contract:** ECS task definition container port must be `8080`; health check path must be `/healthz`; task definition family name agreed with Charlie for `aws ecs describe-task-definition` calls

**Coordination:**
- Coordinate `terraform/main.tf` additions with Beta (use module blocks, avoid root resource conflicts)
- Share `terraform output` values with Agent Charlie when 3.4 is complete

---

### Agent Charlie — CI/CD Pipeline Engineer

**Role:** Owns GitHub Actions workflows. Unblocked after Alpha (Dockerfile) + Delta (infra outputs).

**Assigned Tasks:** 4.1, 4.2, 4.3, 4.4, 4.5, 4.6

**Expected Outputs:**
- `.github/workflows/ci.yml` — OIDC auth, CodeArtifact token, build, push, scan wait, CVE gate
- `.github/workflows/deploy.yml` — dev auto-deploy + prod manual gate
- Evidence: successful E2E pipeline run screenshot + CVE gate failure screenshot

**Interfaces / Contracts with Other Agents:**
- **Requires from Agent Beta:** GitHub Actions IAM role ARN (`role-to-assume`)
- **Requires from Agent Delta:** ECR repo URLs, CodeArtifact repository endpoint and domain, ECS cluster name, service name, task definition family
- **Requires from Agent Alpha:** Dockerfile build arg contract (`APP_VERSION`)
- **Provides to Agent Zeta (Docs):** Pipeline screenshots, logs, and measured pipeline duration

**Coordination:**
- GitHub `production` environment must be created in repo settings with a reviewer before 4.4 can be tested
- Coordinate image promotion strategy (dev SHA → prod ECR) with Delta to confirm IAM permissions allow cross-repo push

---

### Agent Epsilon — Disaster Recovery Engineer

**Role:** Owns RDS, Backup modules, and the DR simulation. Parallel to Delta and Charlie.

**Assigned Tasks:** 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7

**Expected Outputs:**
- `terraform/modules/rds/` — PostgreSQL 16 instance in eu-west-1
- `terraform/modules/backup/` — dual vaults, daily plan, cross-region copy
- `docs/dr-runbook.md` — complete with commands, ARNs, timestamps, and measured RTO

**Interfaces / Contracts with Other Agents:**
- **Requires from Agent Beta:** VPC outputs (private subnets, RDS SG), `aws.dr` provider alias in `providers.tf`
- **Provides to Agent Zeta (Docs):** DR runbook file, RTO measurement, screenshots of backup vault and restore
- **Contract:** RDS instance must be tagged `DR=true` and `Environment=primary` for backup selection to work

**Coordination:**
- Coordinate `terraform/main.tf` additions with Beta (same shared file)
- `AWSBackupDefaultServiceRole` must exist in the account — confirm before running 5.4 (it is AWS-managed but may need activation)
- `aws.dr` provider alias must be in `providers.tf` (Beta's responsibility) before Epsilon can apply backup module

---

### Agent Zeta — Technical Writer / Documentation

**Role:** Owns all documentation. Can draft from early context; finalizes after other agents complete.

**Assigned Tasks:** 6.1 (draft), 6.2, 6.3, 6.4, 6.5

**Expected Outputs:**
- `docs/architecture.md` — both workstream diagrams
- `docs/pipeline-walkthrough.md` + `docs/screenshots/`
- `docs/dr-runbook.md` — finalized with real timestamps
- `README.md` — setup, deploy, demo instructions
- `docs/demo-script.md` — timed walkthrough for submission

**Interfaces / Contracts with Other Agents:**
- **Requires from Agent Charlie:** Screenshots, pipeline run logs, ALB DNS, measured pipeline duration
- **Requires from Agent Epsilon:** Finalized `dr-runbook.md` content (real ARNs, timestamps, RTO)
- **Requires from Agent Delta:** Resource names (cluster, repo URLs) for architecture diagram accuracy

**Coordination:**
- Can draft 6.1 (architecture diagram) and 6.4 (README skeleton) as early as Layer 4 using PRD specs
- Must wait for 4.5, 4.6, 5.7 before finalizing 6.2, 6.3

---

## 6. Parallel Execution Schedule

```
TIME →  T+0      T+1h     T+2h     T+3h     T+4h     T+5h     T+6h     T+7h     T+8h
        │        │        │        │        │        │        │        │        │
ALPHA   ├──1.1──┤├─1.2─┤│
        │       ││       │1.3──────┤
        │       ││                 │1.4─┤
        │       ││
BETA    │       ├┤2.1────┤
        │       │ │      │2.2──────┤
        │       │ │               │2.3 + 2.4 (parallel)────┤
        │       │ │                                        │2.5──┤
        │       │ │
DELTA   │       │ │                                              │3.1 + 3.2 (parallel)──┤
        │       │ │                                              │3.3────────────────────┤
        │       │ │                                                                      │3.4──┤
        │       │ │
CHARLIE │       │ │                                                                           │4.1──┤
        │       │ │                                                                                 │4.2┤
        │       │ │                                                                                    │4.3─┤
        │       │ │                                                                                        │4.4┤4.5┤4.6┤
        │       │ │
EPSILON │       │ │                                   │5.1 + 5.2 (parallel)──────┤
        │       │ │                                                               │5.3──┤
        │       │ │                                                                     │5.4─┤5.5─┤5.6────┤5.7┤
        │       │ │
ZETA    │       │ │                                              │[draft 6.1]─────────────────────────────────┤6.2─┤6.3─┤6.4─┤6.5┤

LAYER   │  L0   │   L1   │         L2         │  L3  │   L4    │      L5        │  L6  │ L7  │     L8 + L9       │
```

**Key Parallel Opportunities:**
1. **L0:** Alpha (app code) + Beta (bootstrap) start immediately — zero dependencies
2. **L2:** VPC and IAM modules (Beta), ECR module (Delta), Backup module (Epsilon), Dockerfile (Alpha) all in parallel
3. **L3–L4:** RDS module (Epsilon) and pipeline infra (Delta) both start from foundation
4. **L8:** E2E test (Charlie), CVE gate test (Charlie), and DR validation (Epsilon) all in parallel

---

## 7. Integration & Testing Plan

### 7.1 Interface Contracts Between Agents

| Contract | Owner | Consumer | Test |
|---|---|---|---|
| Dockerfile build-arg `APP_VERSION` | Alpha | Charlie | `docker build --build-arg APP_VERSION=abc123` succeeds |
| Terraform VPC outputs (subnet IDs, SG IDs) | Beta | Delta, Epsilon | `terraform output` non-null after 2.5 |
| IAM role ARNs | Beta | Charlie, Delta | `aws iam get-role` confirms role exists |
| ECR repo URLs | Delta | Charlie | `aws ecr describe-repositories` confirms repos |
| CodeArtifact endpoint + domain | Delta | Charlie | `pip install fastapi` via endpoint succeeds in CI |
| ECS cluster + service + task family | Delta | Charlie | `aws ecs describe-services` confirms service |
| DR backup vault ARN (eu-central-1) | Epsilon | Epsilon (self, 5.6) | `aws backup list-recovery-points-by-backup-vault` returns points |
| Pipeline screenshots | Charlie | Zeta | Files exist in `docs/screenshots/` |
| DR runbook (with real timestamps) | Epsilon | Zeta | `docs/dr-runbook.md` complete |

### 7.2 Integration Checkpoints

| Checkpoint | When | Validated By |
|---|---|---|
| **CP1:** S3 bucket exists + `terraform init` works | After 2.1 + 2.2 | Agent Beta |
| **CP2:** VPC + IAM apply green | After 2.5 | Agent Beta |
| **CP3:** ECR repos accept image push | After 3.1 + 3.4 | Agent Delta |
| **CP4:** CodeArtifact token fetch + pip install via proxy | After 3.2 + 3.4 | Agent Delta |
| **CP5:** ECS ALB returns healthy for placeholder image | After 3.3 + 3.4 | Agent Delta |
| **CP6:** CI workflow builds and pushes image | After 4.1 + 4.2 | Agent Charlie |
| **CP7:** CVE gate blocks vulnerable image | After 4.6 | Agent Charlie |
| **CP8:** Dev deploy updates ECS + ALB shows new SHA | After 4.5 | Agent Charlie |
| **CP9:** Prod deploy requires manual approval | After 4.4 | Agent Charlie |
| **CP10:** Backup recovery point exists in eu-central-1 | After 5.4 | Agent Epsilon |
| **CP11:** RTO < 30 minutes confirmed | After 5.7 | Agent Epsilon |

### 7.3 Merge Strategy

- Each agent works on a **feature branch** (`feat/agent-alpha`, `feat/agent-beta`, etc.)
- **Shared file conflict zones** — coordinate via PR ordering:
  - `terraform/main.tf` — Beta writes skeleton; Delta and Epsilon add module blocks via PR
  - `README.md` — Zeta owns; others provide content via PR or direct handoff
- Merge order for `terraform/main.tf`:
  1. Beta (foundation modules)
  2. Delta (pipeline infra modules) — merge after Beta
  3. Epsilon (RDS + backup modules) — can merge in parallel with Delta

---

## 8. Risks and Coordination Points

### Risk R1 — Shared `terraform/main.tf` Merge Conflicts
- **Likelihood:** High
- **Impact:** Medium (delays agents Delta and Epsilon)
- **Mitigation:** Beta writes the complete `main.tf` skeleton with empty module blocks as placeholders. Delta and Epsilon fill in their module blocks. Use separate sections clearly delimited by comments.

### Risk R2 — OIDC Trust Policy Requires GitHub Org/Repo Name
- **Likelihood:** Certain (open question in PRD)
- **Impact:** High (blocks 2.4, 4.1)
- **Mitigation:** Confirm `github_org` and `github_repo` values before Beta starts Task 2.4. Use variables so the value can be set at `terraform apply` time without code changes.

### Risk R3 — ECR Scan Delay / Scan Not Available for SHA
- **Likelihood:** Medium
- **Impact:** Medium (4.2 step may timeout)
- **Mitigation:** Use `aws ecr wait image-scan-complete` with appropriate timeout. Add retry logic or `--max-attempts` parameter. Document expected wait time (typically 30–90s).

### Risk R4 — `AWSBackupDefaultServiceRole` Not Activated
- **Likelihood:** Medium (must be enabled first time in account)
- **Impact:** High (blocks 5.4 onward)
- **Mitigation:** Epsilon creates a Terraform resource or adds an `aws_iam_service_linked_role` for AWS Backup before running 5.4. Alternatively, navigate to AWS Backup console to activate the service role.

### Risk R5 — DR Simulation RTO Exceeds 30 Minutes
- **Likelihood:** Low-Medium (RDS restore typically takes 15–25 min for small instances)
- **Impact:** High (PRD requirement)
- **Mitigation:** Use `db.t3.micro` with minimal storage (20 GB) to minimize restore time. Run simulation early (5.7) to confirm RTO. If RTO is exceeded, optimize restore parameters.

### Risk R6 — CodeArtifact Token Expiry During Long Builds
- **Likelihood:** Low
- **Impact:** Low (build-time only)
- **Mitigation:** Fetch token immediately before `docker build` in `ci.yml`. Tokens are valid for 12 hours by default.

### Risk R7 — Prod Image Promotion IAM Permissions
- **Likelihood:** Medium (requires cross-repo ECR push)
- **Impact:** Medium (blocks 4.4)
- **Mitigation:** Delta ensures the GitHub Actions IAM role has `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, etc. on both `fincorp-api-dev` and `fincorp-api-prod` repos. Test in 4.4 before claiming task complete.

### Risk R8 — S3 Native Locking (`use_lockfile = true`) Terraform Version Requirement
- **Likelihood:** Low
- **Impact:** High (all Terraform operations blocked if version mismatch)
- **Mitigation:** Requires Terraform >= 1.10. Beta documents the minimum Terraform version in `README.md` and adds a `required_version` constraint to `providers.tf`.

---

## 9. Summary Table

| Agent | Tasks | Parallelizable With | Hard Blocker |
|---|---|---|---|
| Alpha | 1.1–1.4 | Beta (L0–L2) | None |
| Beta | 2.1–2.5 | Alpha (L0) | S3 bucket must exist before TF init |
| Delta | 3.1–3.4 | Epsilon (L3–L4), Alpha | Beta's 2.5 must complete |
| Epsilon | 5.1–5.7 | Delta (L3–L4) | Beta's 2.5 (VPC); 5.3→5.4→5.5→5.6→5.7 are sequential |
| Charlie | 4.1–4.6 | Epsilon (L5–L8) | Alpha's 1.3 + Delta's 3.4 must complete |
| Zeta | 6.1–6.5 | All (L4 onward, finalize L9) | Charlie's 4.5/4.6 + Epsilon's 5.7 |

**Total estimated wall-clock time (parallel execution): ~7–8 hours**  
**Total estimated sequential execution: ~18–20 hours**  
**Speedup factor from parallelism: ~2.5×**
