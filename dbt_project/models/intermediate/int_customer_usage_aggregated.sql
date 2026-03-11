-- Aggregate usage by customer, day, metric_type.
-- Calculate rolling 7-day and 30-day averages.

WITH daily_usage AS (
    SELECT
        customer_id,
        event_date AS metric_date,
        metric_type,
        SUM(quantity) AS total_quantity,
        COUNT(*) AS event_count,
        MAX(unit) AS unit
    FROM {{ ref('stg_usage_metrics') }}
    GROUP BY 1, 2, 3
),

with_rolling AS (
    SELECT
        *,
        AVG(total_quantity) OVER (
            PARTITION BY customer_id, metric_type
            ORDER BY metric_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7d_avg,
        AVG(total_quantity) OVER (
            PARTITION BY customer_id, metric_type
            ORDER BY metric_date
            ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        ) AS rolling_30d_avg,
        LAG(total_quantity) OVER (
            PARTITION BY customer_id, metric_type
            ORDER BY metric_date
        ) AS prev_day_quantity
    FROM daily_usage
)

SELECT * FROM with_rolling
