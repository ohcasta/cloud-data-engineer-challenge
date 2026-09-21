# Geospatial Ingest Pipeline on AWS

Event-driven pipeline: files land in S3 → a Lambda validates and aggregates
them → results are stored in a PostGIS-enabled PostgreSQL database → an API
Gateway endpoint serves the aggregated data back out.

## Tool selection: why Terraform

Terraform is used as the sole IaC tool. Justification:

- **Native multi-service support** — this stack spans VPC, S3, Lambda, RDS,
  API Gateway, IAM, Secrets Manager, CloudWatch, and AWS Backup. Terraform's
  AWS provider covers all of these with mature, well-documented resources,
  avoiding the need to mix tools (e.g. CDK for compute + CloudFormation for
  networking).
- **Explicit, reviewable dependency graph** — the module boundaries here
  (`networking`, `security`, `s3`, `rds`, `lambda`, `api_gateway`) map
  directly onto the challenge's objectives, and Terraform's plan output
  makes it easy to review exactly what a PR will change before it's applied.
- **State-based lifecycle management** — `terraform destroy` cleanly tears
  down every resource created here, which matters for a take-home/demo
  environment that will likely be spun up and down repeatedly.
- **No AWS-account lock-in** — unlike CDK/SAM, the same HCL applies whether
  this is deployed via local `terraform apply`, Terraform Cloud, or a CI
  pipeline, without an AWS-specific CLI toolchain.

No other IaC tool is used; Terraform alone was sufficient for every resource
required, including the Lambda deployment packages (via the `archive`
provider) and the `psycopg2` layer (built by a small shell script, see
below).

## Requirements traceability

| Evaluation criterion | Where it's satisfied |
|---|---|
| Correctness & completeness of the pipeline | S3 → ingest Lambda → RDS/PostGIS → API Gateway → query Lambda, end to end. Idempotent upserts (`ON CONFLICT (category, source_file)`) so at-least-once delivery can't create duplicate aggregates. |
| Event-driven best practices (S3 triggers, Lambda execution) | Async on-failure destination (SQS DLQ) so failed events aren't silently dropped after retries exhaust; `reserved_concurrent_executions` on the ingest function to bound concurrent RDS connections; least-privilege IAM scoped to specific ARNs, not wildcards; explicit CloudWatch log groups with retention. See [`docs/architecture.md`](docs/architecture.md#event-driven-processing-details). |
| Transformation & aggregation logic in Lambda | `lambda/ingest/handler.py`: per-row schema validation, then group-by-`category` aggregation (count, average, centroid). |
| PostGIS geospatial query optimization | GiST index on the `centroid` column; the query Lambda exposes real spatial filters (`bbox`, `lat`/`lon`/`radius_km`) that the planner satisfies via that index, not just an equality filter. See [`docs/architecture.md`](docs/architecture.md#geospatial-query-optimization). |
| Backup & integrity | AWS Backup daily snapshot of RDS (30-day retention); a separate scheduled Lambda (`lambda/backup/handler.py`) exports `aggregated_data` to `s3://<bucket>/backups/` daily, satisfying "backups to S3" literally, not just via RDS snapshot; S3 bucket versioning + SSE encryption; DLQ preserves failed ingest events for replay instead of losing them. |
| CI/CD (GitHub Actions, pre-commit) | `.github/workflows/terraform.yml` runs fmt/validate/tflint **and** a checkov security scan on every PR (not just locally); `.pre-commit-config.yaml` mirrors this for local hooks, plus detect-secrets. |
| Local testability | `terraform-local/` deploys the real S3/Lambda/API Gateway/IAM/DLQ resources against LocalStack, reusing the same modules and Lambda code as the real-AWS root — see [`docs/local-testing.md`](docs/local-testing.md). |
| Documentation clarity | This README + [`docs/architecture.md`](docs/architecture.md) (diagram, data flow, event-driven design notes, spatial query examples, assumptions). |

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for a diagram and a
full walkthrough of the data flow, networking, and known simplifications.

**Summary:**

- **S3 bucket** (versioned, encrypted, no public access) receives `.csv`
  uploads.
- **Ingest Lambda** (private subnet) is invoked on `s3:ObjectCreated:Put`,
  validates rows, aggregates them by category, and writes to PostgreSQL.
- **RDS PostgreSQL** (private subnet, PostGIS extension) stores the
  `aggregated_data` table with a GiST spatial index on the centroid column.
- **Query Lambda** (private subnet) is invoked by **API Gateway**
  (`GET /aggregated-data`) and reads aggregated rows back out as JSON.
- **VPC** with 2 public + 2 private subnets across 2 AZs; a single **NAT
  Gateway** in a public subnet gives the private-subnet Lambdas outbound
  internet access.
- **Security groups**: Lambda SG allows all egress; RDS SG allows ingress on
  5432 only from the Lambda SG.
- **CloudWatch** log groups (with retention) for both Lambdas and API
  Gateway access logs, plus **CloudWatch Alarms** (→ SNS topic) on Lambda
  errors and throttles.
- **AWS Backup** takes a daily snapshot of the RDS instance (30-day
  retention) — satisfies the "automated backups" bonus objective.
- DB master credentials are generated with `random_password` and stored only
  in **Secrets Manager**; they are never written to Lambda environment
  variables or Terraform outputs.

## Repository layout

```
terraform/                 Root module + environments/dev/terraform.tfvars (real AWS deploy)
  modules/
    networking/             VPC, subnets, IGW, NAT Gateway, route tables
    security/                Security groups (Lambda, RDS)
    s3/                       Ingest bucket
    rds/                      PostgreSQL/PostGIS instance + Secrets Manager
    lambda/                   Ingest + query + backup functions, IAM, log groups, alarms
    api_gateway/              REST API, GET /aggregated-data, access logs
terraform-local/           Same modules, reused against LocalStack (no RDS/VPC) -- see docs/local-testing.md
lambda/
  ingest/handler.py           S3-triggered aggregation logic
  query/handler.py            API Gateway query logic
  backup/handler.py           Scheduled export of aggregated_data to S3
  layers/psycopg2/build.sh    Builds the psycopg2 Lambda layer via Docker
examples/
  sample_data.csv             Valid input file
  sample_data_invalid_rows.csv  Demonstrates schema validation
  s3_put_event.json           Sample S3 PUT event payload
docs/
  architecture.md              Diagram + design notes
  local-testing.md             Terraform + LocalStack walkthrough
docker-compose.yml            Local PostGIS + full LocalStack for local testing
scripts/local_test_ingest.py Run the ingest handler directly against docker-compose
.github/workflows/terraform.yml  CI: terraform fmt/validate, tflint, flake8
.pre-commit-config.yaml       fmt/validate/checkov/detect-secrets hooks
```

## Prerequisites

- Terraform >= 1.6
- AWS CLI configured with credentials that can create VPC/RDS/Lambda/IAM
  resources
- Docker (to build the `psycopg2` Lambda layer, and optionally for local
  testing via `docker-compose.yml`)
- An AWS account with at least 2 Availability Zones available in the chosen
  region (default: `us-east-1`)

## Deployment

1. **Build the psycopg2 Lambda layer** (compiled for the Lambda Linux
   runtime — this cannot simply be `pip install`ed locally on macOS/Windows):

   ```bash
   cd lambda/layers/psycopg2
   ./build.sh
   cd ../../..
   ```

2. **Initialize and apply Terraform**:

   ```bash
   cd terraform
   terraform init
   terraform plan -var-file=environments/dev/terraform.tfvars
   terraform apply -var-file=environments/dev/terraform.tfvars
   ```

   This provisions the VPC, RDS PostGIS instance, both Lambdas, S3 bucket,
   API Gateway, CloudWatch resources, and the AWS Backup plan. RDS
   provisioning typically takes 5-10 minutes.

3. **Trigger the pipeline** by uploading the example file:

   ```bash
   aws s3 cp ../examples/sample_data.csv \
     s3://$(terraform output -raw s3_bucket_name)/raw-data/sample_data.csv
   ```

   The ingest Lambda cold-starts, creates the `postgis` extension, the
   `aggregated_data` table, and its GiST index (first run only), then
   inserts the aggregated rows.

4. **Query the API**:

   ```bash
   curl "$(terraform output -raw api_endpoint)?limit=10"
   curl "$(terraform output -raw api_endpoint)?category=temperature"

   # Spatial queries, backed by the PostGIS GiST index on `centroid`:
   curl "$(terraform output -raw api_endpoint)?lat=40.7128&lon=-74.0060&radius_km=50"
   curl "$(terraform output -raw api_endpoint)?bbox=-125,24,-66,49"
   ```

5. **Inspect logs**:

   ```bash
   aws logs tail /aws/lambda/$(terraform output -raw ingest_lambda_name) --follow
   aws logs tail /aws/lambda/$(terraform output -raw query_lambda_name) --follow
   ```

6. **Tear down** when done:

   ```bash
   terraform destroy -var-file=environments/dev/terraform.tfvars
   ```

## Local testing (before touching AWS)

There are two ways to test locally, at different levels:

1. **Deploy the actual infrastructure with Terraform, against LocalStack**
   (`terraform-local/`) — the real S3 trigger, the real IAM policies, the
   real DLQ, the real API Gateway endpoint, all running locally. This is
   the closest thing to testing the real submission without touching AWS.
   See [`docs/local-testing.md`](docs/local-testing.md) for the full
   walkthrough; short version:

   ```bash
   docker compose up -d
   cd lambda/layers/psycopg2 && ./build.sh && cd ../../..
   cd terraform-local && terraform init && terraform apply -auto-approve && cd ..

   pip install awscli-local  # optional shorthand; plain `aws` works too, see below
   export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
   export AWS_ENDPOINT_URL=http://localhost:4566
   aws s3 cp examples/sample_data.csv \
     s3://$(terraform -chdir=terraform-local output -raw bucket_name)/raw-data/sample_data.csv

   curl "$(terraform -chdir=terraform-local output -raw api_endpoint)?limit=10"
   ```

2. **Run the handler code directly**, no Terraform/Lambda/API Gateway
   involved — fastest inner loop for iterating on the Python logic itself:

   ```bash
   docker compose up -d
   pip install boto3 psycopg2-binary

   awslocal s3 mb s3://local-ingest-bucket  # or: aws s3 mb s3://local-ingest-bucket (with AWS_ENDPOINT_URL set as above)
   awslocal s3 cp examples/sample_data.csv s3://local-ingest-bucket/sample_data.csv

   python scripts/local_test_ingest.py
   ```

   This runs the exact `lambda/ingest/handler.py` code against the local
   services (S3 client pointed at LocalStack, Secrets Manager bypassed in
   favor of the compose file's hardcoded credentials), so schema
   validation, aggregation, and the PostGIS writes can all be verified in
   seconds.

## CI and pre-commit

- `.github/workflows/terraform.yml` runs `terraform fmt -check`,
  `terraform validate`, `tflint`, and `flake8` on every PR touching
  `terraform/` or the Lambda source.
- `.pre-commit-config.yaml` adds the same checks (plus `checkov` for
  security scanning and `detect-secrets` to catch accidentally committed
  credentials) as local git hooks. Install with:

  ```bash
  pip install pre-commit
  pre-commit install
  ```

## Data schema & validation

Input CSV files are expected to have the columns:

```
id,latitude,longitude,category,value
```

Each row is validated before aggregation:

- `latitude` ∈ [-90, 90], `longitude` ∈ [-180, 180], both numeric
- `value` numeric
- `category` non-empty

Rows that fail validation are logged (with the reason and line number) and
skipped; they do not abort processing of the rest of the file. See
`examples/sample_data_invalid_rows.csv` for a file that exercises this path.

Aggregation is intentionally minimal, per the challenge's scope: for each
`category` present in a file, the ingest Lambda computes the row count, the
average of `value`, and a centroid point (mean of `latitude`/`longitude`),
storing the centroid as a native PostGIS `GEOMETRY(Point, 4326)`.

## Assumptions & constraints

- **Single NAT Gateway** (not one per AZ) — reduces cost for a demo/take-home
  deployment. For production HA, add a NAT Gateway per AZ (the `networking`
  module would need one additional resource + per-AZ private route tables).
- **`db.t3.micro`, single-AZ RDS** by default — sized for this exercise, not
  production load. Both are exposed as Terraform variables
  (`db_instance_class`, `db_multi_az`). `ingest_reserved_concurrency`
  (default 10) is sized conservatively under that instance class's
  connection limit; raise both together for higher throughput.
- **DLQ retention is 14 days** — if the ingest Lambda fails repeatedly for a
  given file (bad credentials, RDS unreachable, etc.), the event lands in
  `<project>-ingest-dlq` for that long. Replaying it means re-driving the
  event back through the ingest Lambda manually (e.g.
  `aws lambda invoke --payload <message-body>`); this isn't automated.
- **`skip_final_snapshot = true`** by default, so `terraform destroy` doesn't
  hang waiting for a snapshot during evaluation. Set
  `skip_final_snapshot = false` and `deletion_protection = true` for
  anything long-lived.
- **API Gateway authorization is `NONE`** — the endpoint is public with no
  auth, matching the challenge's request for "a working API Gateway
  endpoint" with minimal ceremony. For production, add an API key/usage
  plan or an IAM/Cognito/JWT authorizer.
- **CSV input format only** — the ingest Lambda parses CSV; GeoJSON or other
  formats would need an additional parser branch keyed off the file
  extension.
- **PostGIS bootstrap happens in Lambda, not Terraform** — RDS doesn't
  expose a way for Terraform to run arbitrary SQL against the instance, so
  `CREATE EXTENSION postgis` and the table/index DDL run idempotently the
  first time the ingest Lambda executes after deployment.
- **No VPC interface endpoints** for S3/Secrets Manager — the NAT Gateway
  handles that egress instead, per the challenge's explicit requirement that
  "Lambda must be in a private subnet and use a NAT Gateway ... for internet
  access." Adding VPC endpoints later would reduce NAT data-transfer costs
  without changing the pipeline's behavior.
- **Region assumption**: examples and `terraform.tfvars` default to
  `us-east-1` with AZs `us-east-1a`/`us-east-1b`; change `aws_region` and
  `azs` together if deploying elsewhere.
