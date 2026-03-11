-- Per-customer usage report with tier classification.
-- Aggregates lifetime usage metrics and classifies customers into tiers.
-- Clustered by usage_tier for efficient tier-based queries.

{{
    config(
        materialized='table',
        cluster_by=["usage_tier"]
    )
}}

WITH usage_by_type AS (
    SELECT
        customer_id,
        metric_type,
        SUM(total_quantity) AS lifetime_quantity,
        MIN(metric_date) AS first_seen_date,
        MAX(metric_date) AS last_seen_date,
        COUNT(DISTINCT metric_date) AS active_days
    FROM {{ ref('int_customer_usage_aggregated') }}
    GROUP BY 1, 2
),

pivoted_usage AS (
    SELECT
        customer_id,
        MIN(first_seen_date) AS first_seen_date,
        MAX(last_seen_date) AS last_seen_date,
        SUM(active_days) AS total_metric_days,
        COUNT(DISTINCT
            CASE WHEN first_seen_date IS NOT NULL THEN customer_id END
        ) AS distinct_metric_types,
        SUM(CASE WHEN metric_type = 'api_calls' THEN lifetime_quantity ELSE 0 END) AS total_api_calls,
        SUM(CASE WHEN metric_type = 'tokens_processed' THEN lifetime_quantity ELSE 0 END) AS total_tokens_processed,
        SUM(CASE WHEN metric_type = 'compute_hours' THEN lifetime_quantity ELSE 0 END) AS total_compute_hours,
        MAX(CASE WHEN metric_type = 'api_calls' THEN active_days ELSE 0 END) AS api_active_days
    FROM usage_by_type
    GROUP BY 1
),

with_tier AS (
    SELECT
        customer_id,
        CASE
            WHEN total_api_calls < 1000 THEN 'free'
            WHEN total_api_calls < 100000 THEN 'growth'
            ELSE 'enterprise'
        END AS usage_tier,
        total_api_calls,
        total_tokens_processed,
        total_compute_hours,
        first_seen_date,
        last_seen_date,
        DATE_DIFF(last_seen_date, first_seen_date, DAY) + 1 AS account_age_days,
        api_active_days AS active_days,
        {{ safe_divide('total_api_calls', 'NULLIF(api_active_days, 0)') }} AS avg_daily_api_calls,
        {{ safe_divide('total_tokens_processed', 'NULLIF(total_api_calls, 0)') }} AS avg_tokens_per_call,
        {{ safe_divide('total_compute_hours', 'NULLIF(api_active_days, 0)') }} AS avg_daily_compute_hours
    FROM pivoted_usage
)

SELECT * FROM with_tier
