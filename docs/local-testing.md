# Testing the pipeline locally with Terraform + LocalStack

This deploys the *actual infrastructure* — S3, Lambda, API Gateway, IAM,
Secrets Manager, SQS, EventBridge — via Terraform against
[LocalStack](https://www.localstack.io/), rather than just invoking a
handler function directly in Python (that lighter-weight option is
`scripts/local_test_ingest.py`, described at the bottom of this doc).

## Why a separate `terraform-local/` root

`terraform/` (the real-AWS config) provisions **RDS** and **AWS Backup**.
Both are LocalStack **Pro** features — the free/Community edition doesn't
emulate them. Rather than pretending a local run is 100% identical to
production, `terraform-local/`:

- Reuses the **exact same** `s3`, `lambda`, and `api_gateway` modules (and
  the exact same Lambda source code in `lambda/`) as `terraform/`.
- Swaps the RDS instance for the `postgis` container already in
  `docker-compose.yml`, and skips the AWS Backup plan entirely.
- Skips the VPC/security-group modules, since LocalStack doesn't enforce
  real network isolation — standing up fake VPC resources wouldn't test
  anything. The Lambda module's `attach_vpc = false` toggle handles this
  without duplicating the module.

Everything else — the S3 event trigger, IAM policies, the DLQ/on-failure
destination, the aggregation logic, the API Gateway contract, the daily
backup-to-S3 export — is exercised for real, against real (emulated) AWS
APIs, not mocked out.

## Prerequisites

- Docker + Docker Compose
- Terraform >= 1.6
- AWS CLI v2 (you almost certainly already have this for the real-AWS
  deployment). Point it at LocalStack for this session:

  ```bash
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_DEFAULT_REGION=us-east-1
  export AWS_ENDPOINT_URL=http://localhost:4566
  ```

  LocalStack accepts any non-empty credentials; `test`/`test` is the usual
  convention. With `AWS_ENDPOINT_URL` set (AWS CLI v2 ≥ 2.13, and boto3
  ≥ 1.28), every plain `aws ...` command below goes to LocalStack
  automatically — no extra tooling needed.

  Prefer a dedicated wrapper instead? `pip install awscli-local` gives you
  an `awslocal` command that does the same thing per-invocation
  (`aws s3 cp ...` ≈ `aws --endpoint-url=http://localhost:4566 s3 cp ...`)
  without needing the environment variables set. Either works; the
  commands below use plain `aws`.

## 1. Start LocalStack + PostGIS

```bash
docker compose up -d
docker compose ps   # wait until both postgis and localstack are healthy
```

`docker-compose.yml` sets `LAMBDA_DOCKER_NETWORK` so that when LocalStack
spins up a Docker container to run a Lambda invocation, that container
joins the same network as `postgis` — meaning `DB_HOST=postgis` resolves
inside the Lambda exactly the way an RDS endpoint hostname would in AWS.

## 2. Build the psycopg2 layer

Same layer, same build script, used by both `terraform/` and
`terraform-local/`:

```bash
cd lambda/layers/psycopg2
./build.sh
cd ../../..
```

## 3. Deploy with Terraform, against LocalStack

```bash
cd terraform-local
terraform init
terraform apply -auto-approve
```

`provider.tf` points every AWS API call at `http://localhost:4566` with
fake static credentials — no extra provider wrapper (e.g. `tflocal`) is
required, though it's a fine alternative if you prefer it.

This takes seconds, not minutes — there's no real RDS instance to wait on.

## 4. Trigger the pipeline

Upload the example file to the prefix the S3 notification is filtered on:

```bash
cd ..
aws s3 cp examples/sample_data.csv \
  s3://$(terraform -chdir=terraform-local output -raw bucket_name)/raw-data/sample_data.csv
```

Check the ingest Lambda actually ran and what it logged:

```bash
aws logs tail /aws/lambda/geo-ingest-local-ingest --since 5m
```

## 5. Query the API

```bash
API=$(terraform -chdir=terraform-local output -raw api_endpoint)

curl "$API?limit=10"
curl "$API?category=temperature"
curl "$API?lat=40.7128&lon=-74.0060&radius_km=50"
curl "$API?bbox=-125,24,-66,49"
```

## 6. Inspect the database directly

Since it's just a container, you can bypass the API and check PostGIS
itself:

```bash
docker exec -it local-postgis psql -U geoadmin -d geodata \
  -c "SELECT category, record_count, avg_value, ST_AsText(centroid) FROM aggregated_data;"
```

## 7. Exercise the failure path (DLQ)

Upload something that will make the ingest Lambda blow up entirely (not
just skip invalid rows — e.g. a file with no valid rows at all, or corrupt
the DB credentials in Secrets Manager first) and confirm it lands in the
dead-letter queue instead of vanishing:

```bash
aws sqs receive-message \
  --queue-url $(terraform -chdir=terraform-local output -raw ingest_dlq_url)
```

## 8. Run the backup export manually

The real EventBridge daily schedule exists locally too, but you don't have
to wait a day to test it:

```bash
aws lambda invoke \
  --function-name $(terraform -chdir=terraform-local output -raw backup_function_name) \
  /dev/stdout

aws s3 ls s3://$(terraform -chdir=terraform-local output -raw bucket_name)/backups/ --recursive
```

## 9. Tear down

```bash
terraform -chdir=terraform-local destroy -auto-approve
docker compose down -v
```

## Known limitations of this local setup

- **No RDS, no AWS Backup, no VPC/NAT/security groups.** These exist only
  in `terraform/` for the real deployment. Local testing validates the
  event-driven logic, the aggregation/query code, the API contract, and
  the IAM/DLQ/scheduling wiring — not RDS provisioning or real network
  isolation.
- **S3 lifecycle configuration is skipped locally**
  (`enable_lifecycle_rule = false` in `terraform-local/main.tf`).
  LocalStack Community's S3 doesn't reliably support the read-after-write
  consistency check Terraform's AWS provider performs after creating
  `aws_s3_bucket_lifecycle_configuration`, which otherwise hangs
  `terraform apply` until a 3-minute timeout. The real-AWS root keeps this
  rule enabled.
- **Every AWS service the stack touches must be listed in `provider.tf`'s
  `endpoints` block**, or Terraform falls through to real AWS for that
  service and fails with `InvalidClientTokenId` against the fake local
  credentials. If you add a resource that uses a new service (e.g. AWS
  Backup, RDS), add its endpoint override too — or, for services LocalStack
  Community can't emulate at all, treat it like RDS/AWS Backup here and
  leave it out of `terraform-local/` entirely.
- **CloudWatch Alarms aren't functionally evaluated** by Community
  LocalStack (the API accepts the alarm definitions, but metric evaluation
  isn't simulated), so `terraform-local/` doesn't create them at all — only
  `terraform/modules/lambda`'s alarms exist, and they're skipped here since
  `terraform-local/main.tf` doesn't reference them (they're internal to the
  `lambda` module and still get created against LocalStack's stub API; they
  just won't ever actually fire).
- **API Gateway invoke URL format**: LocalStack's default is the
  path-style `http://localhost:4566/restapis/<id>/<stage>/_user_request_/<path>`,
  which is what `api_endpoint` outputs. The provider-computed
  `invoke_url_raw` output often reflects a real-AWS-style hostname instead
  and won't resolve locally.
