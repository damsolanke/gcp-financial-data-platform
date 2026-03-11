{% macro date_spine(start_date, end_date) %}
    SELECT date FROM UNNEST(GENERATE_DATE_ARRAY({{ start_date }}, {{ end_date }})) AS date
{% endmacro %}
