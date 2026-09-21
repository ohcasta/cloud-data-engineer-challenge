"""
Query Lambda.

Invoked by API Gateway (GET /aggregated-data). Reads aggregated rows back
out of PostgreSQL/PostGIS and returns them as JSON.

Supported query-string filters (all optional, combinable with `category`
and `limit`; the two spatial modes below are mutually exclusive):

  category=<text>
  limit=<int>                    (default 50, max 500)

  # Radius ("near me") search -- uses ST_DWithin, which is index-aware:
  # Postgres uses idx_aggregated_data_centroid (GiST) to prune to a
  # bounding box before doing the precise distance check.
  lat=<float>&lon=<float>[&radius_km=<float>]   (radius_km default 10)

  # Bounding-box search -- uses the `&&` overlap operator, the canonical
  # GiST-index-driven spatial predicate in PostGIS.
  min_lon=<float>&min_lat=<float>&max_lon=<float>&max_lat=<float>

Without lat/lon or a bbox, the query behaves exactly as before (no
spatial predicate, no index use) -- this is intentionally backward
compatible for plain category/limit lookups.
"""
import json
import logging
import os

import boto3
import psycopg2
from psycopg2.extras import RealDictCursor

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")

DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ["DB_NAME"]

_cached_secret = None

BASE_COLUMNS = """
    id, category, record_count, avg_value,
    ST_X(centroid) AS longitude, ST_Y(centroid) AS latitude,
    source_file, created_at
"""

MAX_RADIUS_KM = 20000  # ~ half the Earth's circumference; a generous cap
DEFAULT_RADIUS_KM = 10


def get_db_credentials():
    global _cached_secret
    if _cached_secret is None:
        resp = secrets_client.get_secret_value(SecretId=DB_SECRET_ARN)
        _cached_secret = json.loads(resp["SecretString"])
    return _cached_secret


def get_connection():
    creds = get_db_credentials()
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=creds["username"],
        password=creds["password"],
        connect_timeout=5,
    )


def _response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, default=str),
    }


class QueryParamError(ValueError):
    pass


def _parse_float(params, key):
    raw = params.get(key)
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        raise QueryParamError(f"'{key}' must be a number")


def parse_limit(params):
    try:
        limit = int(params.get("limit", 50))
    except (TypeError, ValueError):
        raise QueryParamError("'limit' must be an integer")
    return max(1, min(limit, 500))


def parse_near(params):
    """Return (lat, lon, radius_km) if a radius search was requested,
    None if neither lat nor lon was given, or raise QueryParamError for
    a partial/invalid combination."""
    lat = _parse_float(params, "lat")
    lon = _parse_float(params, "lon")
    if lat is None and lon is None:
        return None
    if lat is None or lon is None:
        raise QueryParamError("'lat' and 'lon' must be provided together")
    if not (-90.0 <= lat <= 90.0):
        raise QueryParamError("'lat' must be between -90 and 90")
    if not (-180.0 <= lon <= 180.0):
        raise QueryParamError("'lon' must be between -180 and 180")

    radius_km = params.get("radius_km")
    if radius_km is None:
        radius_km = DEFAULT_RADIUS_KM
    else:
        radius_km = _parse_float(params, "radius_km")
    if radius_km <= 0 or radius_km > MAX_RADIUS_KM:
        raise QueryParamError(f"'radius_km' must be between 0 and {MAX_RADIUS_KM}")

    return lat, lon, radius_km


def parse_bbox(params):
    """Return (min_lon, min_lat, max_lon, max_lat) if a bbox search was
    requested, None if none of the four params was given, or raise
    QueryParamError for a partial/invalid combination."""
    keys = ("min_lon", "min_lat", "max_lon", "max_lat")
    values = {k: _parse_float(params, k) for k in keys}
    if all(v is None for v in values.values()):
        return None
    if any(v is None for v in values.values()):
        raise QueryParamError(f"{keys} must all be provided together")

    min_lon, min_lat, max_lon, max_lat = (
        values["min_lon"], values["min_lat"], values["max_lon"], values["max_lat"]
    )
    for lon in (min_lon, max_lon):
        if not (-180.0 <= lon <= 180.0):
            raise QueryParamError("longitude values must be between -180 and 180")
    for lat in (min_lat, max_lat):
        if not (-90.0 <= lat <= 90.0):
            raise QueryParamError("latitude values must be between -90 and 90")
    if min_lon >= max_lon or min_lat >= max_lat:
        raise QueryParamError("min_lon/min_lat must be less than max_lon/max_lat")

    return min_lon, min_lat, max_lon, max_lat


def build_query(params):
    """Build (sql, params) for the requested filters. Raises
    QueryParamError on invalid or conflicting input."""
    limit = parse_limit(params)
    category = params.get("category")
    near = parse_near(params)
    bbox = parse_bbox(params)

    if near and bbox:
        raise QueryParamError(
            "cannot combine a near-point search (lat/lon) with a bbox search"
        )

    select_extra = ""
    select_params = []
    conditions = []
    where_params = []
    order_clause = "ORDER BY created_at DESC"

    if category:
        conditions.append("category = %s")
        where_params.append(category)

    if near:
        lat, lon, radius_km = near
        radius_m = radius_km * 1000.0

        # Index-aware: ST_DWithin uses the GiST index (idx_aggregated_data_centroid)
        # to prune candidates by bounding box before the exact distance check.
        conditions.append(
            "ST_DWithin("
            "centroid::geography, "
            "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, "
            "%s)"
        )
        where_params.extend([lon, lat, radius_m])

        select_extra = (
            ", ST_Distance("
            "centroid::geography, "
            "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography"
            ") / 1000.0 AS distance_km"
        )
        select_params = [lon, lat]
        order_clause = "ORDER BY distance_km ASC"

    elif bbox:
        min_lon, min_lat, max_lon, max_lat = bbox
        # The && overlap operator is the canonical GiST-index-driven
        # spatial predicate in PostGIS.
        conditions.append("centroid && ST_MakeEnvelope(%s, %s, %s, %s, 4326)")
        where_params.extend([min_lon, min_lat, max_lon, max_lat])

    where_clause = f"WHERE {' AND '.join(conditions)}" if conditions else ""

    sql = f"""
        SELECT {BASE_COLUMNS}{select_extra}
        FROM aggregated_data
        {where_clause}
        {order_clause}
        LIMIT %s
    """
    all_params = select_params + where_params + [limit]
    return sql, all_params


def lambda_handler(event, context):
    params = (event or {}).get("queryStringParameters") or {}

    try:
        sql, query_params = build_query(params)
    except QueryParamError as exc:
        return _response(400, {"error": str(exc)})

    conn = None
    try:
        conn = get_connection()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, query_params)
            rows = cur.fetchall()

        return _response(200, {"count": len(rows), "items": rows})
    except Exception:
        logger.exception("Query failed")
        return _response(500, {"error": "internal server error"})
    finally:
        if conn is not None:
            conn.close()