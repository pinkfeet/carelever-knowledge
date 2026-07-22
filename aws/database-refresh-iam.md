# Database Refresh — Required IAM Access

Date: 2026-07-20

## Overview

The RDS database refresh tool (`carelever_rds_database_refresh`) runs **locally** on
your machine and orchestrates AWS RDS/ECS operations across three accounts via
cross-account IAM roles (assumed from the `carelever-identity` account,
`976782234542`). It does **not** run over SSH.

`DeveloperReadOnly` is **not sufficient** — every stage except SQL scrubbing makes
write calls. This doc lists the exact permissions needed so you can request a
least-privilege role instead of full `AdminRole`.

## Accounts

| Environment | Account ID     | Profile (config)       |
| ----------- | -------------- | ---------------------- |
| Production  | `082429435416` | `carelever-production` |
| Staging     | `283367951244` | `carelever-staging`    |
| Development | `862999456217` | `carelever-development`|

Identity account (source): `976782234542` (user e.g. `jc.shin`).

Note: reading your own IAM entitlements is blocked by an explicit-deny policy
(`IamSelfService`), so you can't self-enumerate assumable roles. The definitive
test is `aws sts assume-role` (or console Switch Role) against a target ARN.

## Actions the script actually uses

Derived from `helpers/snapshot_utils.py`, `rds_utils.py`, `ecs_utils.py`.

- **Prod** (share a snapshot): `DescribeDBClusterSnapshots`, `CopyDBClusterSnapshot`,
  `ModifyDBClusterSnapshotAttribute`, `AddTagsToResource` + KMS on the prod key.
- **Nonprod** (restore → swap → recycle): `Describe*`, `CopyDBClusterSnapshot`,
  `RestoreDBClusterFromSnapshot`, `CreateDBInstance`, `ModifyDBCluster`,
  `ModifyDBInstance`, `StopDBCluster`, `AddTagsToResource`; ECS `ListServices`,
  `DescribeServices`, `UpdateService`; + KMS on the nonprod key.

## Least-privilege policies

### PROD account (`082429435416`) — snapshot share only

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "RdsSnapshotShare", "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusterSnapshots",
        "rds:CopyDBClusterSnapshot",
        "rds:ModifyDBClusterSnapshotAttribute",
        "rds:AddTagsToResource"
      ], "Resource": "*" },
    { "Sid": "KmsSnapshotCopy", "Effect": "Allow",
      "Action": ["kms:DescribeKey","kms:CreateGrant","kms:Decrypt",
        "kms:GenerateDataKey*","kms:ReEncrypt*"],
      "Resource": "arn:aws:kms:ap-southeast-2:082429435416:key/72a3a6b0-611a-4f3d-a404-0e2de58d5777" }
  ]
}
```

### DEV (`862999456217`) + STAGING (`283367951244`) — restore, swap, recycle

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "RdsRefresh", "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusters","rds:DescribeDBInstances","rds:DescribeDBClusterSnapshots",
        "rds:CopyDBClusterSnapshot","rds:RestoreDBClusterFromSnapshot","rds:CreateDBInstance",
        "rds:ModifyDBCluster","rds:ModifyDBInstance","rds:StopDBCluster","rds:AddTagsToResource"
      ], "Resource": "*" },
    { "Sid": "EcsRecycle", "Effect": "Allow",
      "Action": ["ecs:ListServices","ecs:DescribeServices","ecs:UpdateService"],
      "Resource": "*" },
    { "Sid": "KmsSnapshotCopy", "Effect": "Allow",
      "Action": ["kms:DescribeKey","kms:CreateGrant","kms:Decrypt",
        "kms:GenerateDataKey*","kms:ReEncrypt*"], "Resource": "*" }
  ]
}
```

## What to ask the admin (Itoc / CloudOps)

1. Create a role (e.g. `DatabaseRefresh`) in **all three** accounts with the policy
   above (prod gets the narrower one). Trust policy = `976782234542:root` with
   `aws:MultiFactorAuthPresent = true` (same shape as the existing cross-account roles).
2. Grant your identity user **`sts:AssumeRole`** on those three role ARNs — this is the
   piece currently missing (`DeveloperReadOnly` users get AccessDenied on `AssumeRole`
   for write roles).

## Other prerequisites

- **KMS key policies** on the prod key and each nonprod key must permit cross-account
  share / re-encrypt. Likely already configured (Itoc's script relied on it), but confirm.
- **Stage 3 (scrubbing)** connects directly to the DB over the **Kinnect Shared VPN**
  using a DB password — not IAM. Requires VPN access + prod/nonprod DB passwords.
- Alternatively, have **Itoc run the refresh** — per the repo README it's their script
  under an additional-services agreement.
