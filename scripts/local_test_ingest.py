#!/usr/bin/env python3
"""
Runs the ingest Lambda handler locally against the docker-compose services
(local PostgreSQL/PostGIS + LocalStack S3), without needing AWS credentials
or a real Lambda deployment.

Prerequisites:
    docker compose up -d
    pip install boto3 psycopg2-binary
    aws --endpoint-url=http://localhost:4566 s3 mb s3://local-ingest-bucket
    aws --endpoint-url=http://localhost:4566 s3 cp examples/sample_data.csv \
        s3://local-ingest-bucket/sample_data.csv

Usage:
    python scripts/local_test_ingest.py
"""
import json
import os
import sys
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "lambda", "ingest"))

os.environ.setdefault("DB_HOST", "localhost")
os.environ.setdefault("DB_NAME", "geodata")
os.environ.setdefault("DB_SECRET_ARN", "local-fake-secret")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import boto3  # noqa: E402

import handler  # noqa: E402  (lambda/ingest/handler.py)

# Point boto3's S3 client at LocalStack instead of real AWS.
handler.s3 = boto3.client("s3", endpoint_url="http://localhost:4566")

# Bypass Secrets Manager entirely for local testing — use the docker-compose
# credentials directly.
handler.get_db_credentials = lambda: {
    "username": "geoadmin",
    "password": "localdevpassword",
}

event = {
    "Records": [
        {
            "s3": {
                "bucket": {"name": "local-ingest-bucket"},
                "object": {"key": "sample_data.csv"},
            }
        }
    ]
}

result = handler.lambda_handler(event, None)
print(json.dumps(result, indent=2))
