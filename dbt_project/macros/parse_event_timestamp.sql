{#-
    parse_event_timestamp(column_name)

    Parse an RFC 3339 / ISO 8601 event timestamp string into a TIMESTAMP.

    Rows in fdp_<env>_raw carry `timestamp` exactly as the ingestion service
    published it (schemas/*.json, format: date-time). Two producers emit two
    shapes and both must parse:

      - scripts/generate_sample_data.py (Python datetime.isoformat()):
            2025-01-15T10:30:00.123456+00:00   microseconds + numeric offset
      - hand-written clients / README examples:
            2025-01-15T10:30:00Z               no fraction, Z suffix

    %E*S accepts seconds with any number of fractional digits (or none) and
    %Ez accepts an RFC 3339 numeric offset (+HH:MM / -HH:MM). %Ez does not
    match a bare "Z", so a trailing Z is normalised to +00:00 first.

    Unit tests: models/staging/schema.yml (unit_tests:).
-#}
{% macro parse_event_timestamp(column_name) -%}
    PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S%Ez',
        REGEXP_REPLACE({{ column_name }}, r'[Zz]$', '+00:00')
    )
{%- endmacro %}
