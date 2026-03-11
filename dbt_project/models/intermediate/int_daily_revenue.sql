-- Aggregate revenue by day, product_line, region, currency.
-- Convert all amounts to USD using seed exchange rates.

WITH daily_revenue AS (
    SELECT
        event_date AS revenue_date,
        product_line,
        region,
        currency,
        COUNT(*) AS transaction_count,
        SUM(amount_cents) AS total_amount_cents,
        AVG(amount_cents) AS avg_amount_cents,
        MIN(amount_cents) AS min_amount_cents,
        MAX(amount_cents) AS max_amount_cents
    FROM {{ ref('stg_revenue_transactions') }}
    GROUP BY 1, 2, 3, 4
),

with_usd AS (
    SELECT
        dr.*,
        COALESCE(er.rate_to_usd, 1.0) AS exchange_rate,
        ROUND(dr.total_amount_cents * COALESCE(er.rate_to_usd, 1.0)) AS total_amount_cents_usd,
        ROUND(dr.avg_amount_cents * COALESCE(er.rate_to_usd, 1.0)) AS avg_amount_cents_usd
    FROM daily_revenue dr
    LEFT JOIN {{ ref('currency_exchange_rates') }} er
        ON dr.currency = er.currency_code
)

SELECT * FROM with_usd
