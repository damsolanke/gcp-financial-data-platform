-- Pivot cost records by category, aggregate by cost_center and month.
-- Calculate percentage allocation per category.

WITH monthly_costs AS (
    SELECT
        cost_center,
        DATE_TRUNC(event_date, MONTH) AS cost_month,
        category,
        currency,
        SUM(amount_cents) AS total_amount_cents,
        COUNT(*) AS record_count
    FROM {{ ref('stg_cost_records') }}
    GROUP BY 1, 2, 3, 4
),

pivoted AS (
    SELECT
        cost_center,
        cost_month,
        currency,
        SUM(CASE WHEN category = 'compute' THEN total_amount_cents ELSE 0 END) AS compute_cents,
        SUM(CASE WHEN category = 'storage' THEN total_amount_cents ELSE 0 END) AS storage_cents,
        SUM(CASE WHEN category = 'network' THEN total_amount_cents ELSE 0 END) AS network_cents,
        SUM(CASE WHEN category = 'personnel' THEN total_amount_cents ELSE 0 END) AS personnel_cents,
        SUM(total_amount_cents) AS total_cents,
        SUM(record_count) AS total_records
    FROM monthly_costs
    GROUP BY 1, 2, 3
),

with_percentages AS (
    SELECT
        *,
        {{ safe_divide('compute_cents', 'total_cents') }} AS compute_pct,
        {{ safe_divide('storage_cents', 'total_cents') }} AS storage_pct,
        {{ safe_divide('network_cents', 'total_cents') }} AS network_pct,
        {{ safe_divide('personnel_cents', 'total_cents') }} AS personnel_pct
    FROM pivoted
)

SELECT * FROM with_percentages
