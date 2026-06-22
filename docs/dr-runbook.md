# DR Runbook — FinCorp RDS Failover (eu-west-1 → eu-central-1)

**RTO Target:** < 30 minutes  
**Primary Region:** eu-west-1 (Ireland)  
**DR Region:** eu-central-1 (Frankfurt)  
**RDS Identifier:** `fincorp-postgres`  
**Backup Vault (primary):** `fincorp-primary-vault`  
**Backup Vault (DR):** `fincorp-dr-vault`

---

## Prerequisites

- AWS CLI configured with credentials that have `rds:*`, `backup:*`, and `sts:*` permissions
- `jq` installed locally
- Account ID available: `export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`

---

## Normal State

The primary RDS instance (`fincorp-postgres`) runs in eu-west-1. AWS Backup runs daily at 02:00 UTC, retaining 7 days in `fincorp-primary-vault` and automatically copying each recovery point to `fincorp-dr-vault` in eu-central-1, where it is retained for 14 days.

Verify backup vault contents:
```bash
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-primary-vault \
  --region eu-west-1 \
  --query 'RecoveryPoints[*].{Status:Status,Created:CreationDate,ARN:RecoveryPointArn}' \
  --output table
```

---

## Step 0 — Force an immediate backup (before simulation)

If the daily backup has not yet run, force one now:
```bash
aws backup start-backup-job \
  --backup-vault-name fincorp-primary-vault \
  --resource-arn $(aws rds describe-db-instances \
      --db-instance-identifier fincorp-postgres \
      --region eu-west-1 \
      --query 'DBInstances[0].DBInstanceArn' \
      --output text) \
  --iam-role-arn arn:aws:iam::${ACCOUNT_ID}:role/service-role/AWSBackupDefaultServiceRole \
  --region eu-west-1
```

Wait for the job to reach COMPLETED status (typically 5–10 minutes for a fresh empty instance):
```bash
JOB_ID=<job-id-from-above>
watch -n 15 "aws backup describe-backup-job --backup-job-id ${JOB_ID} --region eu-west-1 --query State --output text"
```

Then confirm the cross-region copy is available in eu-central-1 (allow up to 5 additional minutes):
```bash
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-dr-vault \
  --region eu-central-1 \
  --query 'RecoveryPoints[*].{Status:Status,Created:CreationDate,ARN:RecoveryPointArn}' \
  --output table
```

Record the DR recovery point ARN:
```bash
export DR_RECOVERY_POINT_ARN=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-dr-vault \
  --region eu-central-1 \
  --query 'RecoveryPoints | sort_by(@, &CreationDate) | [-1].RecoveryPointArn' \
  --output text)
echo "DR Recovery Point ARN: ${DR_RECOVERY_POINT_ARN}"
```

---

## Step 1 — Simulate region failure (delete primary RDS)

> **Record start timestamp before running this command.**

```bash
export SIMULATION_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Simulation started at: ${SIMULATION_START}"

aws rds delete-db-instance \
  --db-instance-identifier fincorp-postgres \
  --skip-final-snapshot \
  --region eu-west-1
```

Wait for deletion to complete:
```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier fincorp-postgres \
  --region eu-west-1
echo "RDS instance deleted at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
```

---

## Step 2 — Identify recovery point in eu-central-1

```bash
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-dr-vault \
  --region eu-central-1 \
  --query 'RecoveryPoints[*].{Status:Status,Created:CreationDate,ARN:RecoveryPointArn}' \
  --output table
```

Confirm `$DR_RECOVERY_POINT_ARN` is set from Step 0. If not:
```bash
export DR_RECOVERY_POINT_ARN=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name fincorp-dr-vault \
  --region eu-central-1 \
  --query 'RecoveryPoints | sort_by(@, &CreationDate) | [-1].RecoveryPointArn' \
  --output text)
```

---

## Step 3 — Restore from backup in eu-central-1

```bash
export RESTORE_JOB=$(aws backup start-restore-job \
  --recovery-point-arn "${DR_RECOVERY_POINT_ARN}" \
  --iam-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/service-role/AWSBackupDefaultServiceRole" \
  --region eu-central-1 \
  --metadata '{
    "DBInstanceIdentifier": "fincorp-postgres-dr",
    "DBInstanceClass": "db.t3.micro",
    "Engine": "postgres",
    "MultiAZ": "false",
    "PubliclyAccessible": "false"
  }' \
  --query RestoreJobId \
  --output text)

echo "Restore job started: ${RESTORE_JOB} at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
```

Monitor restore job status:
```bash
watch -n 30 "aws backup describe-restore-job \
  --restore-job-id ${RESTORE_JOB} \
  --region eu-central-1 \
  --query '{Status:Status,PercentDone:PercentDone}' \
  --output table"
```

---

## Step 4 — Validate restored instance

Wait for the RDS instance to become available in eu-central-1:
```bash
aws rds wait db-instance-available \
  --db-instance-identifier fincorp-postgres-dr \
  --region eu-central-1

export RESTORE_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Instance available at: ${RESTORE_END}"
```

Confirm endpoint and PostgreSQL version:
```bash
aws rds describe-db-instances \
  --db-instance-identifier fincorp-postgres-dr \
  --region eu-central-1 \
  --query 'DBInstances[0].{Endpoint:Endpoint.Address,Port:Endpoint.Port,Engine:Engine,EngineVersion:EngineVersion,Status:DBInstanceStatus}' \
  --output table
```

---

## Step 5 — Record RTO

```bash
echo "Simulation start:    ${SIMULATION_START}"
echo "Instance available:  ${RESTORE_END}"
# Calculate elapsed (requires GNU date)
START_EPOCH=$(date -d "${SIMULATION_START}" +%s)
END_EPOCH=$(date -d "${RESTORE_END}" +%s)
ELAPSED=$(( (END_EPOCH - START_EPOCH) / 60 ))
echo "Elapsed time: ${ELAPSED} minutes"
if [ "${ELAPSED}" -lt 30 ]; then
  echo "RTO TARGET MET: ${ELAPSED} minutes < 30 minutes"
else
  echo "RTO TARGET MISSED: ${ELAPSED} minutes >= 30 minutes"
fi
```

---

## Simulation Results (fill in after execution)

| Step | Timestamp | Notes |
|------|-----------|-------|
| Simulation start (Step 1) | `FILL_IN` | |
| Deletion complete | `FILL_IN` | |
| Restore job started (Step 3) | `FILL_IN` | Restore job ID: `FILL_IN` |
| Instance available (Step 4) | `FILL_IN` | |
| **Total elapsed** | **FILL_IN minutes** | Target: < 30 min |

**DR endpoint (eu-central-1):** `FILL_IN`  
**PostgreSQL version confirmed:** `FILL_IN`  
**RTO achieved:** `FILL_IN minutes`
