-- Unit economics by product line and month.
-- Joins revenue, usage, and cost data to calculate per-unit metrics.
-- Partitioned by month, clustered by product_line.

{{
    config(
        materialized='table',
        partition_by={
            "field": "economics_month",
            "data_type": "date",
            "granularity": "month"
        },
        cluster_by=["product_line"]
    )
}}

WITH monthly_revenue AS (
    SELECT
        DATE_TRUNC(revenue_date, MONTH) AS economics_month,
        product_line,
        SUM(total_amount_cents_usd) AS total_revenue_cents_usd,
        {{ cents_to_dollars('SUM(total_amount_cents_usd)') }} AS total_revenue_usd,
        SUM(transaction_count) AS total_transactions
    FROM {{ ref('int_daily_revenue') }}
    GROUP BY 1, 2
),

monthly_usage AS (
    SELECT
        DATE_TRUNC(metric_date, MONTH) AS economics_month,
        SUM(CASE WHEN metric_type = 'api_calls' THEN total_quantity ELSE 0 END) AS total_api_calls,
        SUM(CASE WHEN metric_type = 'tokens_processed' THEN total_quantity ELSE 0 END) AS total_tokens_processed,
        SUM(CASE WHEN metric_type = 'compute_hours' THEN total_quantity ELSE 0 END) AS total_compute_hours,
        COUNT(DISTINCT customer_id) AS active_customers
    FROM {{ ref('int_customer_usage_aggregated') }}
    GROUP BY 1
),

monthly_costs AS (
    SELECT
        cost_month AS economics_month,
        SUM(total_cents) AS total_cost_cents,
        {{ cents_to_dollars('SUM(total_cents)') }} AS total_cost_usd,
        SUM(compute_cents) AS compute_cost_cents,
        SUM(personnel_cents) AS personnel_cost_cents
    FROM {{ ref('int_cost_by_center') }}
    GROUP BY 1
),

combined AS (
    SELECT
        mr.economics_month,
        mr.product_line,
        mr.total_revenue_usd,
        mr.total_transactions,
        mu.total_api_calls,
        mu.total_tokens_processed,
        mu.total_compute_hours,
        mu.active_customers,
        mc.total_cost_usd,

        -- Revenue per unit metrics
        {{ safe_divide('mr.total_revenue_usd', 'NULLIF(mu.total_api_calls, 0)') }} AS revenue_per_api_call,
        {{ safe_divide('mr.total_revenue_usd', 'NULLIF(mu.total_tokens_processed, 0)') }} AS revenue_per_token,
        {{ safe_divide('mr.total_revenue_usd', 'NULLIF(mu.total_compute_hours, 0)') }} AS revenue_per_compute_hour,
        {{ safe_divide('mr.total_revenue_usd', 'NULLIF(mu.active_customers, 0)') }} AS revenue_per_customer,

        -- Cost per unit metrics
        {{ safe_divide('mc.total_cost_usd', 'NULLIF(mu.total_api_calls, 0)') }} AS cost_per_api_call,
        {{ safe_divide('mc.total_cost_usd', 'NULLIF(mu.total_compute_hours, 0)') }} AS cost_per_compute_hour,
        {{ safe_divide('mc.total_cost_usd', 'NULLIF(mu.active_customers, 0)') }} AS cost_per_customer,

        -- Margin
        mr.total_revenue_usd - COALESCE(mc.total_cost_usd, 0) AS gross_margin_usd,
        {{ safe_divide(
            'mr.total_revenue_usd - COALESCE(mc.total_cost_usd, 0)',
            'NULLIF(mr.total_revenue_usd, 0)'
        ) }} AS gross_margin_pct
    FROM monthly_revenue mr
    LEFT JOIN monthly_usage mu
        ON mr.economics_month = mu.economics_month
    LEFT JOIN monthly_costs mc
        ON mr.economics_month = mc.economics_month
)

SELECT * FROM combined
