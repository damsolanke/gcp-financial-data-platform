-- Ensure every revenue transaction customer has at least one usage metric.
-- Orphan transactions may indicate data pipeline issues.
SELECT rt.customer_id
FROM {{ ref('stg_revenue_transactions') }} rt
LEFT JOIN (
    SELECT DISTINCT customer_id
    FROM {{ ref('stg_usage_metrics') }}
) um ON rt.customer_id = um.customer_id
WHERE um.customer_id IS NULL
GROUP BY 1
