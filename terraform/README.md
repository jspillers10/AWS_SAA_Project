# Terraform: Secure Multi-Tier Web App

Infrastructure as Code version of the console build documented in the main [README](../README.md). One `terraform apply` stands up the whole environment; one `git push` deploys the app.

## Layout

```
terraform/
  main.tf, variables.tf, outputs.tf, versions.tf
  terraform.tfvars.example     lab-friendly values (cheap, easy teardown)
  backend.tf.example           S3 remote state with native locking
  modules/
    network/     VPC, 6 subnets over 2 AZs, IGW, NAT GW per AZ, route tables, NACLs, flow logs
    security/    alb-sg, app-sg, rds-sg, codebuild-migrate-sg (SG-to-SG references only)
    database/    RDS MySQL 8.4 Multi-AZ, param group (TLS enforced), master + app secrets
    storage/     static / logs / artifacts buckets, optional CloudFront + OAC
    compute/     ec2-webapp-role, launch template (IMDSv2, encrypted gp3), ALB, TG, ASG, scaling
    waf/         WAFv2 on the ALB: AWS managed rules + per-IP rate limit
    cicd/        CodeCommit or GitHub, CodeBuild (build + in-VPC migrate), CodeDeploy, CodePipeline V2
    monitoring/  SNS, the 5 alarms, dashboard
app/                           contents of the CodeCommit/GitHub repo the pipeline deploys
  appspec.yml, buildspec.yml, webapp/, scripts/, db/migrate.py
```

## Pipeline flow

```
git push -> Source -> Build (php -l, package) -> Migrate (CodeBuild in private subnets,
            master secret, idempotent schema + app user) -> Deploy (CodeDeploy, OneAtATime,
            ALB-aware, auto rollback)
```

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set alert_email, review cost knobs
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Confirm the SNS subscription email, then push the app:

```bash
# CodeCommit (needs git-remote-codecommit or HTTPS Git credentials)
pip install git-remote-codecommit
cd ../app
git init -b main && git add . && git commit -m "initial app"
git remote add origin codecommit::us-east-2://prod-webapp
git push -u origin main
```

For GitHub instead: set `source_provider = "github"` and `github_repository = "owner/repo"`, apply, then open the `github_connection_arn` output in the console (Developer Tools > Connections) and click **Update pending connection** once.

Until the first pipeline run finishes, instances serve a placeholder page. Health checks still pass because user data drops `/health.php`.

## Teardown

```bash
terraform destroy
```

With the example tfvars, deletion protection is off, the final snapshot is skipped, and secrets delete immediately. With the defaults in `variables.tf`, you'll need to flip those first.

## What changed from the console build

The console README lists several gaps as "designed but not implemented." This version implements them:

| Original | Here |
|---|---|
| Service-linked roles only; custom `ec2-webapp-role` documented but skipped | `ec2-webapp-role` + instance profile with SSM, CloudWatch agent, and scoped S3/Secrets Manager access |
| CodeDeploy stuck on `HEALTH_CONSTRAINTS` | Instance role can read the artifacts bucket (what the agent actually needs; `AWSCodeDeployRole` belongs on the CodeDeploy service role), agent installed in user data, health check decoupled from the DB |
| DB password defaulted in user data | Random passwords in Secrets Manager. Instances only get the least-privilege app user; master creds are only readable by the in-VPC migration job |
| DB init SQL "documented, not executed" | `db/migrate.py` runs every pipeline execution, idempotently |
| Plaintext DB connection | `require_secure_transport=1`, app and migration both verify against the RDS CA bundle |
| NACLs described | NACLs on app and DB subnets |
| No WAF | WAFv2 with IP reputation, common, known bad inputs, SQLi, PHP, Linux rule sets + rate limit |
| CloudFront with OAI | CloudFront with OAC (OAI is legacy), toggle via `enable_cloudfront` |
| Health check on `/index.php` (writes a DB row every 30s per target) | `/health.php`, no DB dependency |
| Instance metadata showed N/A | `index.php` uses IMDSv2 tokens |
| MySQL 8.0.35 | 8.4 LTS. 8.0 left RDS standard support in July 2026, so it now bills Extended Support |
| RDS connections alarm at 150 | Default 50. `db.t3.micro` max_connections is well under 150, so the original alarm could never fire |
| SSH from bastion-sg | No SSH at all; Session Manager only |

Also added: VPC flow logs, ALB access logs, S3 TLS-only bucket policies, `drop_invalid_header_fields` on the ALB, rolling instance refresh on launch template changes, CloudWatch agent shipping Apache and CodeDeploy agent logs.

## Cost (us-east-2, rough)

| Item | Per hour |
|---|---|
| 2x NAT Gateway (1 with `single_nat_gateway = true`) | ~$0.09 ($0.045) |
| RDS db.t3.micro Multi-AZ | ~$0.034 |
| ALB | ~$0.0225 + LCU |
| 2x t3.micro | ~$0.021 |
| WAF | ~$0.015 (web ACL + rules, prorated) |

About $0.20/hr with defaults. Destroy when you're done.

## Tests

Offline plan tests with mocked providers (no AWS creds, no cost). They exercise the default CodeCommit path, the GitHub + CloudFront + HTTPS + single-NAT path, and input validation:

```bash
terraform init -backend=false
terraform test
```

## Static analysis

Scanned with Checkov. Remaining findings are deliberate for a portfolio-scale build:

- **KMS CMKs** (S3, Secrets Manager, CloudWatch Logs, CodeBuild, pipeline artifacts, SNS): AWS-managed keys used everywhere to avoid $1/key/month and key policy sprawl. SNS is unencrypted because CloudWatch alarms can't publish to a topic encrypted with the AWS-managed key.
- **`Resource: "*"`** on the CodeBuild VPC ENI describe calls and CodeDeploy `RunInstances`: those actions don't support resource-level scoping.
- **Port 80 open on the ALB**: expected until `acm_certificate_arn` is set, which switches HTTP to a 301 redirect.
- **Secrets rotation off**: instances read the secret at boot, so rotation would need a refresh hook. Next step below.
- S3 checks on PAB/versioning are false positives from `for_each`; they're applied.

## Next steps

- Secrets rotation with an ASG instance refresh (or have PHP read the secret at runtime with caching)
- Swap NAT for VPC interface endpoints (SSM, Secrets Manager, CodeDeploy, logs) + S3 gateway endpoint
- CloudTrail + GuardDuty + Security Hub in a separate `baseline` stack
- Terratest or `terraform test` for the network module
