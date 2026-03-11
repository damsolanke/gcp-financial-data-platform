-- Monthly cost rollup with percentage allocation by category and budget variance.
-- Partitioned by cost_month, clustered by cost_center.

{{
    config(
        materialized='table',
        partition_by={
            "field": "cost_month",
            "data_type": "date",
            "granularity": "month"
        },
        cluster_by=["cost_center"]
    )
}}

WITH cost_data AS (
    SELECT
        cost_center,
        cost_month,
        currency,
        compute_cents,
        storage_cents,
        network_cents,
        personnel_cents,
        total_cents,
        total_records,
        compute_pct,
        storage_pct,
        network_pct,
        personnel_pct
    FROM {{ ref('int_cost_by_center') }}
),

with_dollars_and_budget AS (
    SELECT
        cost_center,
        cost_month,
        currency,

        -- Category totals in cents
        compute_cents,
        storage_cents,
        network_cents,
        personnel_cents,
        total_cents,

        -- Category totals in dollars
        {{ cents_to_dollars('compute_cents') }} AS compute_usd,
        {{ cents_to_dollars('storage_cents') }} AS storage_usd,
        {{ cents_to_dollars('network_cents') }} AS network_usd,
        {{ cents_to_dollars('personnel_cents') }} AS personnel_usd,
        {{ cents_to_dollars('total_cents') }} AS total_usd,

        -- Category percentages
        compute_pct,
        storage_pct,
        network_pct,
        personnel_pct,

        total_records,

        -- Budget placeholders (to be populated from a budget source)
        CAST(NULL AS FLOAT64) AS budget_amount_usd,
        CAST(NULL AS FLOAT64) AS budget_variance_usd,
        CAST(NULL AS FLOAT64) AS budget_variance_pct,

        -- Hierarchy enrichment
        cch.department,
        cch.division
    FROM cost_data cd
    LEFT JOIN {{ ref('cost_center_hierarchy') }} cch
        ON cd.cost_center = cch.cost_center
)

SELECT * FROM with_dollars_and_budget
