"""
Ingest Lambda.

Triggered by S3 `PUT` events. Reads the uploaded CSV file, validates each
row against a minimal schema, aggregates the valid rows by `category`
(count, average value, and a PostGIS centroid point), and upserts the
results into the `aggregated_data` table in PostgreSQL/PostGIS.

Idempotency: S3 -> Lambda notifications are at-least-once, so the same
event can arrive more than once (Lambda retries, S3 redelivery, etc).
Two layers guard against duplicate aggregate rows:

  1. A `processed_files` ledger keyed on (bucket, object_key, dedupe_key)
     where dedupe_key is the S3 object's versionId (if bucket versioning
     is on) or ETag otherwise. Claiming a row and storing the aggregates
     happen in the SAME transaction, so a crash between the two rolls
     both back and the next retry reprocesses cleanly.
  2. A UNIQUE (category, source_file) constraint on `aggregated_data`
     with an ON CONFLICT ... DO UPDATE, so even a reprocess that slips
     past the ledger (e.g. a manual re-run) overwrites instead of
     duplicating.
"""
import csv
import io
import json
import logging
import os

import boto3
import psycopg2
from psycopg2.extras import execute_values

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
secrets_client = boto3.client("secretsmanager")

DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ["DB_NAME"]

REQUIRED_COLUMNS = {"id", "latitude", "longitude", "category", "value"}

# Cached across warm invocations to avoid repeated Secrets Manager calls.
_cached_secret = None


def get_db_credentials():
    global _cached_secret
    if _cached_secret is None:
        logger.info("Fetching DB credentials from Secrets Manager")
        resp = secrets_client.get_secret_value(SecretId=DB_SECRET_ARN)
        _cached_secret = json.loads(resp["SecretString"])
    return _cached_secret


def get_connection():
    creds = get_db_credentials()
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=creds["username"],
        password=creds["password"],
        connect_timeout=5,
    )
    conn.autocommit = False
    return conn


def ensure_schema(conn):
    """Idempotently enable PostGIS and create/upgrade the tables/indexes.

    RDS does not let Terraform execute arbitrary SQL against the instance,
    so bootstrapping the extension/schema here (on first Lambda cold start)
    keeps the whole pipeline self-contained. This function is safe to run
    against a table that already exists from before this idempotency fix
    was introduced: the constraint is added via a guarded DO block rather
    than assumed to already be there.
    """
    with conn.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS postgis;")
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS aggregated_data (
                id SERIAL PRIMARY KEY,
                category TEXT NOT NULL,
                record_count INTEGER NOT NULL,
                avg_value DOUBLE PRECISION,
                centroid GEOMETRY(Point, 4326),
                source_file TEXT,
                created_at TIMESTAMPTZ DEFAULT now()
            );
            """
        )
        # Spatial index for efficient geospatial queries (bonus requirement).
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_aggregated_data_centroid
            ON aggregated_data USING GIST (centroid);
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_aggregated_data_category
            ON aggregated_data (category);
            """
        )
        # One row per (category, source_file): lets us upsert instead of
        # blindly inserting duplicates when a file is reprocessed.
        cur.execute(
            """
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_aggregated_data_category_source'
                ) THEN
                    ALTER TABLE aggregated_data
                    ADD CONSTRAINT uq_aggregated_data_category_source
                    UNIQUE (category, source_file);
                END IF;
            END $$;
            """
        )
        # Ledger of S3 object versions we've fully processed, used to make
        # a retried/duplicate invocation a cheap no-op.
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS processed_files (
                bucket TEXT NOT NULL,
                object_key TEXT NOT NULL,
                dedupe_key TEXT NOT NULL,
                processed_at TIMESTAMPTZ DEFAULT now(),
                PRIMARY KEY (bucket, object_key, dedupe_key)
            );
            """
        )
    conn.commit()


def get_dedupe_key(s3_object):
    """Return a token that uniquely identifies this exact upload.

    Prefers the S3 object versionId (present when bucket versioning is
    enabled), since it's unambiguous even if two uploads happen to produce
    identical bytes. Falls back to the ETag, which still changes whenever
    the object's content changes, and is always present regardless of
    versioning configuration.
    """
    version_id = s3_object.get("versionId")
    if version_id and version_id != "null":
        return f"v:{version_id}"
    return f"etag:{s3_object.get('eTag', '')}"


def validate_row(row, line_number):
    """Minimal schema validation. Raises ValueError with a descriptive
    message for any row that doesn't meet the schema, so bad rows can be
    logged and skipped without failing the whole file."""
    missing = REQUIRED_COLUMNS - row.keys()
    if missing:
        raise ValueError(f"line {line_number}: missing columns {sorted(missing)}")

    try:
        lat = float(row["latitude"])
        lon = float(row["longitude"])
        value = float(row["value"])
    except (TypeError, ValueError) as exc:
        raise ValueError(f"line {line_number}: non-numeric field ({exc})")

    if not (-90.0 <= lat <= 90.0):
        raise ValueError(f"line {line_number}: latitude {lat} out of range")
    if not (-180.0 <= lon <= 180.0):
        raise ValueError(f"line {line_number}: longitude {lon} out of range")
    if not row["category"] or not row["category"].strip():
        raise ValueError(f"line {line_number}: empty category")

    return {
        "latitude": lat,
        "longitude": lon,
        "category": row["category"].strip(),
        "value": value,
    }


def aggregate(rows):
    """Minimal aggregation: group by category, compute count, average
    value, and a centroid (mean lat/lon) per category."""
    buckets = {}
    for r in rows:
        bucket = buckets.setdefault(r["category"], {"values": [], "lats": [], "lons": []})
        bucket["values"].append(r["value"])
        bucket["lats"].append(r["latitude"])
        bucket["lons"].append(r["longitude"])

    results = []
    for category, bucket in buckets.items():
        count = len(bucket["values"])
        avg_value = sum(bucket["values"]) / count
        centroid_lat = sum(bucket["lats"]) / count
        centroid_lon = sum(bucket["lons"]) / count
        results.append((category, count, avg_value, centroid_lon, centroid_lat))
    return results


def claim_file(conn, bucket, key, dedupe_key):
    """Attempt to atomically claim this exact S3 object version for
    processing. Returns True if this invocation should (re)process the
    file, False if a previous invocation already completed it.

    Deliberately does NOT commit here — the caller commits this together
    with the aggregate upsert in one transaction, so a failure between
    claiming and storing rolls both back and a retry starts fresh.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO processed_files (bucket, object_key, dedupe_key)
            VALUES (%s, %s, %s)
            ON CONFLICT (bucket, object_key, dedupe_key) DO NOTHING
            RETURNING 1
            """,
            (bucket, key, dedupe_key),
        )
        return cur.fetchone() is not None


def store_aggregates(conn, aggregates, source_file):
    """Upsert aggregates for a file. ON CONFLICT overwrites the previous
    result for a (category, source_file) pair rather than duplicating it,
    which also makes an intentional reprocess of a corrected file safe."""
    with conn.cursor() as cur:
        execute_values(
            cur,
            """
            INSERT INTO aggregated_data
                (category, record_count, avg_value, centroid, source_file)
            VALUES %s
            ON CONFLICT (category, source_file) DO UPDATE SET
                record_count = EXCLUDED.record_count,
                avg_value = EXCLUDED.avg_value,
                centroid = EXCLUDED.centroid,
                created_at = now()
            """,
            [
                (cat, count, avg_value, f"SRID=4326;POINT({lon} {lat})", source_file)
                for cat, count, avg_value, lon, lat in aggregates
            ],
            template="(%s, %s, %s, ST_GeomFromEWKT(%s), %s)",
        )
    # No commit here: the caller commits together with claim_file().


def lambda_handler(event, context):
    conn = None
    processed_files = 0
    skipped_duplicates = 0
    try:
        for record in event.get("Records", []):
            bucket = record["s3"]["bucket"]["name"]
            key = record["s3"]["object"]["key"]
            dedupe_key = get_dedupe_key(record["s3"]["object"])
            logger.info("Processing s3://%s/%s (dedupe_key=%s)", bucket, key, dedupe_key)

            if conn is None:
                conn = get_connection()
                ensure_schema(conn)

            # Claim first, before doing any parsing work, so a duplicate
            # delivery of an already-processed file is a cheap no-op.
            if not claim_file(conn, bucket, key, dedupe_key):
                conn.commit()  # release the (no-op) transaction cleanly
                logger.info(
                    "Skipping s3://%s/%s: already processed (dedupe_key=%s)",
                    bucket, key, dedupe_key,
                )
                skipped_duplicates += 1
                continue

            try:
                obj = s3.get_object(Bucket=bucket, Key=key)
                content = obj["Body"].read().decode("utf-8")

                reader = csv.DictReader(io.StringIO(content))
                valid_rows, errors = [], []
                for i, row in enumerate(reader, start=2):  # line 1 is the header
                    try:
                        valid_rows.append(validate_row(row, i))
                    except ValueError as exc:
                        errors.append(str(exc))
                        logger.warning("Skipping invalid row: %s", exc)

                if not valid_rows:
                    logger.error(
                        "No valid rows in %s; skipping file. Errors: %s", key, errors
                    )
                    # Still commit the claim: there's nothing to store, and
                    # retrying won't change that unless the file itself
                    # changes (which would carry a different dedupe_key).
                    conn.commit()
                    continue

                aggregates = aggregate(valid_rows)
                store_aggregates(conn, aggregates, key)

                # Claim + aggregates commit together: either both stick,
                # or (on any exception above) neither does.
                conn.commit()
                processed_files += 1

                logger.info(
                    "Stored %d aggregate row(s) from %s (%d valid / %d invalid input rows)",
                    len(aggregates),
                    key,
                    len(valid_rows),
                    len(errors),
                )
            except Exception:
                conn.rollback()  # undo the claim too, so a retry reprocesses
                raise

        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "message": "processed",
                    "files": processed_files,
                    "skipped_duplicates": skipped_duplicates,
                }
            ),
        }
    except Exception:
        logger.exception("Failed to process S3 event")
        raise
    finally:
        if conn is not None:
            conn.close()
