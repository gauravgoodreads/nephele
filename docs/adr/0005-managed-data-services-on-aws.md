# 0005. Managed RDS and ElastiCache on AWS, wired in with ExternalName Services

## Context

Locally, PostgreSQL and Redis run in the cluster as StatefulSets. In the
cloud, running stateful services yourself means owning backups, patching,
failover and disk management.

## Decision

On AWS, use Amazon RDS for PostgreSQL (encrypted, 7-day automated backups,
optional Multi-AZ standby) and Amazon ElastiCache for Redis. The AWS overlay
deletes the in-cluster StatefulSets and the backup CronJob, and patches the
`db` and `redis` Services into `ExternalName` Services that point at the
managed endpoints.

## Consequences

- No application setting changes between environments: the apps always
  connect to `db` and `redis`.
- AWS takes over backups and patching; RDS snapshots replace the CronJob.
- Costs more per hour than in-cluster pods (see the cost section of the
  report), and ties the data layer to AWS.
- RDS for PostgreSQL 15 enforces TLS by default; the original drivers do not
  use TLS, so `rds.force_ssl` is relaxed inside the private subnets. Turning
  TLS on in the drivers is future work.

## Evidence

`terraform validate` passes and the AWS overlay renders in CI. Not applied:
the available AWS account's organisation policy denies EKS, EC2, RDS and ECR.
