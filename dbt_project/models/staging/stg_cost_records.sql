-- Staging model for cost records.
-- Deduplicates by record_id (latest ingestion_timestamp wins), parses the
-- RFC 3339 timestamp via parse_event_timestamp, adds surrogate key.
-- Source schema: schemas/cost_record.json

WITH source AS (
    SELECT * FROM {{ source('raw', 'raw_cost_records') }}
),

deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY record_id
            ORDER BY ingestion_timestamp DESC
        ) AS _row_num
    FROM source
),

cleaned AS (
    SELECT
        record_id,
        {{ parse_event_timestamp('timestamp') }} AS event_timestamp,
        DATE({{ parse_event_timestamp('timestamp') }}) AS event_date,
        cost_center,
        category,
        amount_cents,
        currency,
        vendor,
        description,
        {{ dbt_utils.generate_surrogate_key(['record_id']) }} AS surrogate_key,
        ingestion_timestamp,
        'pubsub_ingestion' AS source_system
    FROM deduplicated
    WHERE _row_num = 1
)

SELECT * FROM cleaned
