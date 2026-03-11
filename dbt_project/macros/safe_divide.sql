{% macro safe_divide(numerator, denominator) %}
    SAFE_DIVIDE({{ numerator }}, {{ denominator }})
{% endmacro %}
