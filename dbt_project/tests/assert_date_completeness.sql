-- Ensure no gaps in the revenue date spine.
-- Missing dates indicate pipeline failures or data loss.
WITH date_spine AS (
    {{ date_spine("'" ~ var('start_date') ~ "'", "'" ~ var('end_date') ~ "'") }}
),

revenue_dates AS (
    SELECT DISTINCT revenue_date
    FROM {{ ref('fct_daily_revenue_summary') }}
)

SELECT ds.date AS missing_date
FROM date_spine ds
LEFT JOIN revenue_dates rd ON ds.date = rd.revenue_date
WHERE rd.revenue_date IS NULL
