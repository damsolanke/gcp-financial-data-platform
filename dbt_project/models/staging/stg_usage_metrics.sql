-- Staging model for usage metrics.
-- Deduplicates by metric_id, casts types, adds surrogate key.
-- Source schema: schemas/usage_metric.json

WITH source AS (
    SELECT * FROM {{ source('raw', 'raw_usage_metrics') }}
),

deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY metric_id
            ORDER BY ingestion_timestamp DESC
        ) AS _row_num
    FROM source
),

cleaned AS (
    SELECT
        metric_id,
        PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S%Ez', timestamp) AS event_timestamp,
        DATE(PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S%Ez', timestamp)) AS event_date,
        customer_id,
        metric_type,
        quantity,
        unit,
        metadata,
        {{ dbt_utils.generate_surrogate_key(['metric_id']) }} AS surrogate_key,
        ingestion_timestamp,
        'pubsub_ingestion' AS source_system
    FROM deduplicated
    WHERE _row_num = 1
)

SELECT * FROM cleaned
