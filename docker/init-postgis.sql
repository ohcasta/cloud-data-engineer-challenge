CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS aggregated_data (
    id SERIAL PRIMARY KEY,
    category TEXT NOT NULL,
    record_count INTEGER NOT NULL,
    avg_value DOUBLE PRECISION,
    centroid GEOMETRY(Point, 4326),
    source_file TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT uq_aggregated_data_category_source UNIQUE (category, source_file)
);

CREATE INDEX IF NOT EXISTS idx_aggregated_data_centroid
    ON aggregated_data USING GIST (centroid);

CREATE INDEX IF NOT EXISTS idx_aggregated_data_category
    ON aggregated_data (category);
