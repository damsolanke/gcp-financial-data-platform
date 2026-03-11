{% macro cents_to_dollars(column_name) %}
    ROUND(CAST({{ column_name }} AS FLOAT64) / 100.0, 2)
{% endmacro %}
