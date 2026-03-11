-- Staging model for revenue transactions.
-- Deduplicates by transaction_id, casts types, adds surrogate key.
-- Source schema: schemas/revenue_transaction.json

WITH source AS (
    SELECT * FROM {{ source('raw', 'raw_revenue_transactions') }}
),

deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY transaction_id
            ORDER BY ingestion_timestamp DESC
        ) AS _row_num
    FROM source
),

cleaned AS (
    SELECT
        transaction_id,
        PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S%Ez', timestamp) AS event_timestamp,
        DATE(PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S%Ez', timestamp)) AS event_date,
        amount_cents,
        currency,
        customer_id,
        product_line,
        region,
        metadata,
        {{ dbt_utils.generate_surrogate_key(['transaction_id']) }} AS surrogate_key,
        ingestion_timestamp,
        'pubsub_ingestion' AS source_system
    FROM deduplicated
    WHERE _row_num = 1
)

SELECT * FROM cleaned
