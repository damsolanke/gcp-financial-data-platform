-- Cross-tabulation of revenue by product line and region with running totals.
-- Partitioned by revenue_date, clustered by product_line, region.

{{
    config(
        materialized='table',
        partition_by={
            "field": "revenue_date",
            "data_type": "date",
            "granularity": "day"
        },
        cluster_by=["product_line", "region"]
    )
}}

WITH daily_base AS (
    SELECT
        revenue_date,
        product_line,
        region,
        SUM(total_amount_cents_usd) AS total_cents_usd,
        SUM(transaction_count) AS transaction_count
    FROM {{ ref('int_daily_revenue') }}
    GROUP BY 1, 2, 3
),

region_pivot AS (
    SELECT
        revenue_date,
        product_line,
        region,
        transaction_count,
        {{ cents_to_dollars('total_cents_usd') }} AS total_revenue_usd,
        {{ cents_to_dollars('SUM(CASE WHEN region = \'us-east\' THEN total_cents_usd ELSE 0 END) OVER (PARTITION BY revenue_date, product_line)') }} AS us_east_revenue_usd,
        {{ cents_to_dollars('SUM(CASE WHEN region = \'us-west\' THEN total_cents_usd ELSE 0 END) OVER (PARTITION BY revenue_date, product_line)') }} AS us_west_revenue_usd,
        {{ cents_to_dollars('SUM(CASE WHEN region = \'eu-west\' THEN total_cents_usd ELSE 0 END) OVER (PARTITION BY revenue_date, product_line)') }} AS eu_west_revenue_usd,
        {{ cents_to_dollars('SUM(CASE WHEN region = \'ap-southeast\' THEN total_cents_usd ELSE 0 END) OVER (PARTITION BY revenue_date, product_line)') }} AS ap_southeast_revenue_usd,
        {{ cents_to_dollars('SUM(total_cents_usd) OVER (PARTITION BY revenue_date, product_line)') }} AS product_total_revenue_usd
    FROM daily_base
),

with_running_totals AS (
    SELECT
        *,
        SUM(total_revenue_usd) OVER (
            PARTITION BY product_line, region
            ORDER BY revenue_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_total_revenue_usd,
        SUM(transaction_count) OVER (
            PARTITION BY product_line, region
            ORDER BY revenue_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_total_transactions,

        -- Product-level display name
        plm.display_name AS product_display_name,
        plm.business_unit
    FROM region_pivot rp
    LEFT JOIN {{ ref('product_line_mapping') }} plm
        ON rp.product_line = plm.product_line
)

SELECT * FROM with_running_totals
