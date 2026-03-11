-- Daily revenue summary with day-over-day and week-over-week growth.
-- Partitioned by revenue_date, clustered by product_line, region.
-- This is the primary revenue reporting table.

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

WITH daily AS (
    SELECT
        revenue_date,
        product_line,
        region,
        SUM(transaction_count) AS transaction_count,
        SUM(total_amount_cents_usd) AS total_revenue_cents_usd,
        {{ cents_to_dollars('SUM(total_amount_cents_usd)') }} AS total_revenue_usd,
        SUM(avg_amount_cents_usd) AS avg_transaction_cents_usd
    FROM {{ ref('int_daily_revenue') }}
    GROUP BY 1, 2, 3
),

with_growth AS (
    SELECT
        *,
        -- Day-over-day growth
        LAG(total_revenue_usd) OVER (
            PARTITION BY product_line, region ORDER BY revenue_date
        ) AS prev_day_revenue_usd,
        {{ safe_divide(
            'total_revenue_usd - LAG(total_revenue_usd) OVER (PARTITION BY product_line, region ORDER BY revenue_date)',
            'NULLIF(LAG(total_revenue_usd) OVER (PARTITION BY product_line, region ORDER BY revenue_date), 0)'
        ) }} AS dod_growth_rate,

        -- Week-over-week growth
        LAG(total_revenue_usd, 7) OVER (
            PARTITION BY product_line, region ORDER BY revenue_date
        ) AS prev_week_revenue_usd,
        {{ safe_divide(
            'total_revenue_usd - LAG(total_revenue_usd, 7) OVER (PARTITION BY product_line, region ORDER BY revenue_date)',
            'NULLIF(LAG(total_revenue_usd, 7) OVER (PARTITION BY product_line, region ORDER BY revenue_date), 0)'
        ) }} AS wow_growth_rate,

        -- Running monthly total
        SUM(total_revenue_usd) OVER (
            PARTITION BY product_line, region, DATE_TRUNC(revenue_date, MONTH)
            ORDER BY revenue_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS mtd_revenue_usd
    FROM daily
)

SELECT * FROM with_growth
