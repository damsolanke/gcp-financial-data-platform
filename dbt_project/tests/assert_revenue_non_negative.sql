-- Ensure no negative revenue in the daily summary.
SELECT *
FROM {{ ref('fct_daily_revenue_summary') }}
WHERE total_revenue_usd < 0
