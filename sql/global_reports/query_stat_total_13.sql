WITH excluded_users AS (
    --statements executed by these roles (monitoring agents, cloud provider internal admin) are left out of the report
    SELECT unnest(ARRAY['cloudadmin', 'cloudsqladmin', 'datadog']::text[]) AS rolname
),
pg_stat_statements_normalized AS (
    SELECT
        *,
        --parallel workers' I/O time is summed across all workers while execution time is wall-clock time,
        --so I/O time can exceed the statement's total time; cap it so that CPU time never goes negative
        least(blk_read_time + blk_write_time, total_plan_time + total_exec_time) AS io_time,
        translate( regexp_replace( regexp_replace( regexp_replace( regexp_replace(query, E'\\?(::[a-zA-Z_]+)?( *, *\\?(::[a-zA-Z_]+)?)+', '?', 'g'), E'\\$[0-9]+(::[a-zA-Z_]+)?( *, *\\$[0-9]+(::[a-zA-Z_]+)?)*', '$N', 'g'), E'--.*$', '', 'ng'), E'/\\*.*?\\*/', '', 'g'), E'\r', '') AS query_normalized
    --if current database is postgres then generate report for all databases otherwise generate for current database only
    FROM pg_stat_statements
    WHERE (
        current_database() = 'postgres'
        OR dbid IN (
            SELECT oid
            FROM pg_database
            WHERE datname = current_database()
        )
    )
        AND userid NOT IN (
        SELECT r.oid
        FROM pg_roles r
        JOIN excluded_users USING (rolname)
    )
    --skip executions of this report itself
        AND query NOT LIKE '%pg_stat_statements_normalized%'
),
totals AS (
    SELECT
        SUM(total_plan_time + total_exec_time) AS total_time,
        SUM(io_time) AS io_time,
        SUM(total_plan_time + total_exec_time-io_time) AS cpu_time,
        SUM(calls) AS ncalls,
        SUM(ROWS) AS total_rows
    FROM pg_stat_statements_normalized
),
_pg_stat_statements AS (
    SELECT
        coalesce( (
        SELECT datname
        FROM pg_database
        WHERE oid = p.dbid
    ), 'unknown') AS database,
        coalesce( (
        SELECT rolname
        FROM pg_roles
        WHERE oid = p.userid
    ), 'unknown') AS username,
    --select shortest query, replace \n\n-- strings to avoid email clients format text as footer
    substring( translate( replace( (array_agg(query ORDER BY length(query)))[1], E'-- \n', E'--\n'), E'\r', ''), 1, 8192) AS query,
        SUM(total_plan_time + total_exec_time) AS total_time,
        SUM(io_time) AS io_time,
        MIN(min_exec_time) AS min_exec_time,
        MAX(max_exec_time) AS max_exec_time,
        SUM(calls) AS calls,
        SUM(ROWS) AS ROWS
    FROM pg_stat_statements_normalized p
    WHERE calls > 0
    GROUP BY
        dbid,
        userid,
        md5(query_normalized)
),
totals_readable AS (
    SELECT
        to_char(interval '1 millisecond' * total_time, 'HH24:MI:SS') AS total_time,
        (100*io_time/greatest(total_time, 1))::numeric(20, 2) AS io_time_percent,
        to_char(ncalls, 'FM999,999,999,990') AS total_queries, (
        SELECT to_char(COUNT(DISTINCT md5(query)), 'FM999,999,990')
        FROM _pg_stat_statements
    ) AS unique_queries
    FROM totals
),
statements AS (
    SELECT
        (100*total_time/ (
        SELECT greatest(total_time, 1)
        FROM totals
    )) AS time_percent,
        (100*io_time/ (
        SELECT greatest(io_time, 1)
        FROM totals
    )) AS io_time_percent,
        (100*(total_time-io_time)/ (
        SELECT greatest(cpu_time, 1)
        FROM totals
    )) AS cpu_time_percent,
        to_char(interval '1 millisecond' * total_time, 'HH24:MI:SS') AS total_time,
        (total_time::numeric/calls)::numeric(20, 2) AS avg_time,
        ((total_time-io_time)::numeric/calls)::numeric(20, 2) AS avg_cpu_time,
        (io_time::numeric/calls)::numeric(20, 2) AS avg_io_time,
        min_exec_time::numeric(20, 2) AS min_exec_time,
        max_exec_time::numeric(20, 2) AS max_exec_time,
        to_char(calls, 'FM999,999,999,990') AS calls,
        (100*calls/ (
        SELECT greatest(ncalls, 1)
        FROM totals
    ))::numeric(20, 2) AS calls_percent,
        to_char(ROWS, 'FM999,999,999,990') AS ROWS,
        (100*ROWS/ (
        SELECT greatest(total_rows, 1)
        FROM totals
    ))::numeric(20, 2) AS row_percent,
        database,
        username,
        query
    FROM _pg_stat_statements
    WHERE ( (
                total_time-io_time
            )/ (
            SELECT greatest(cpu_time, 1)
            FROM totals
        ) >= 0.01
            OR (
                io_time
            )/ (
            SELECT greatest(io_time, 1)
            FROM totals
        ) >= 0.01
            OR calls/ (
            SELECT greatest(ncalls, 1)
            FROM totals
        ) >= 0.02
            OR ROWS/ (
            SELECT greatest(total_rows, 1)
            FROM totals
        ) >= 0.02
        )
    UNION ALL
    SELECT
        (100*SUM(total_time)::numeric/ (
        SELECT greatest(total_time, 1)
        FROM totals
    )) AS time_percent,
        (100*SUM(io_time)::numeric/ (
        SELECT greatest(io_time, 1)
        FROM totals
    )) AS io_time_percent,
        (100*SUM(total_time-io_time)::numeric/ (
        SELECT greatest(cpu_time, 1)
        FROM totals
    )) AS cpu_time_percent,
        to_char(interval '1 millisecond' * SUM(total_time), 'HH24:MI:SS') AS total_time,
        (SUM(total_time)::numeric/SUM(calls))::numeric(20, 2) AS avg_time,
        (SUM(total_time-io_time)::numeric/SUM(calls))::numeric(20, 2) AS avg_cpu_time,
        (SUM(io_time)::numeric/SUM(calls))::numeric(20, 2) AS avg_io_time,
        MIN(min_exec_time)::numeric(20, 2) AS min_exec_time,
        MAX(max_exec_time)::numeric(20, 2) AS max_exec_time,
        to_char(SUM(calls), 'FM999,999,999,990') AS calls,
        (100*SUM(calls)/ (
        SELECT greatest(ncalls, 1)
        FROM totals
    ))::numeric(20, 2) AS calls_percent,
        to_char(SUM(ROWS), 'FM999,999,999,990') AS ROWS,
        (100*SUM(ROWS)/ (
        SELECT greatest(total_rows, 1)
        FROM totals
    ))::numeric(20, 2) AS row_percent,
        'all' AS database,
        'all' AS username,
        'other' AS query
    FROM _pg_stat_statements
    WHERE NOT ( (
                total_time-io_time
            )/ (
            SELECT greatest(cpu_time, 1)
            FROM totals
        ) >= 0.01
            OR (
                io_time
            )/ (
            SELECT greatest(io_time, 1)
            FROM totals
        ) >= 0.01
            OR calls/ (
            SELECT greatest(ncalls, 1)
            FROM totals
        ) >= 0.02
            OR ROWS/ (
            SELECT greatest(total_rows, 1)
            FROM totals
        ) >= 0.02
        )
),
statements_readable AS (
    SELECT
        row_number() OVER (ORDER BY s.time_percent DESC) AS pos,
        to_char(time_percent, 'FM990.0') || '%' AS time_percent,
        to_char(io_time_percent, 'FM990.0') || '%' AS io_time_percent,
        to_char(cpu_time_percent, 'FM990.0') || '%' AS cpu_time_percent,
        to_char(avg_io_time*100/(coalesce(nullif(avg_time, 0), 1)), 'FM990.0') || '%' AS avg_io_time_percent,
        total_time,
        avg_time,
        avg_cpu_time,
        avg_io_time,
        min_exec_time,
        max_exec_time,
        calls,
        calls_percent,
        ROWS,
        row_percent,
        database,
        username,
        query
    FROM statements s
    WHERE calls IS NOT NULL
)
SELECT E'total time:\t' || total_time || ' (IO: ' || io_time_percent || E'%)\n' || E'total queries:\t' || total_queries || ' (unique: ' || unique_queries || E')\n' || 'report for ' || (
    SELECT  CASE
        WHEN current_database() = 'postgres'  THEN 'all databases'
        ELSE current_database() || ' database'
    END
) || E', version 0.9.6' || ' @ PostgreSQL ' || (
    SELECT setting
    FROM pg_settings
    WHERE name = 'server_version'
) || E'\ntracking ' || (
    SELECT setting
    FROM pg_settings
    WHERE name = 'pg_stat_statements.track'
) || ' ' || (
    SELECT setting
    FROM pg_settings
    WHERE name = 'pg_stat_statements.max'
) || ' queries, utilities ' || (
    SELECT setting
    FROM pg_settings
    WHERE name = 'pg_stat_statements.track_utility'
) || ', logging ' || (
    SELECT (CASE WHEN setting = '0' THEN 'all' WHEN setting = '-1' THEN 'none' WHEN setting::int > 1000 THEN (setting::numeric/1000)::numeric(20, 1) || 's+' ELSE setting || 'ms+' END)
    FROM pg_settings
    WHERE name = 'log_min_duration_statement'
) || E' queries\n' || 'statistics reset: ' || (
    --pg_stat_statements_info only exists from pg_stat_statements 1.9 (PostgreSQL 14) onwards, so it is
    --queried through query_to_xml() to avoid failing to parse this report on older versions
    SELECT CASE
        WHEN to_regclass('pg_stat_statements_info') IS NULL THEN 'unknown (requires pg_stat_statements 1.9+)'
        ELSE substring(query_to_xml($$
            SELECT to_char(stats_reset AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC (' || date_trunc('second', now() - stats_reset) || ' ago), entries deallocated: ' || dealloc AS info
            FROM pg_stat_statements_info
        $$, false, true, '')::text FROM '<info>(.*)</info>')
    END
) || E'\n' || 'excluded users: ' || (
    SELECT coalesce(string_agg(rolname, ', ' ORDER BY rolname), 'none')
    FROM excluded_users
) || E'\n' || (
    SELECT coalesce(string_agg('WARNING: database ' || datname || ' must be vacuumed within ' || to_char(2147483647 - age(datfrozenxid), 'FM999,999,999,990') || ' transactions', E'\n' ORDER BY age(datfrozenxid) DESC) || E'\n', '')
    FROM pg_database
    WHERE (
            2147483647 - age(datfrozenxid)
        ) < 200000000
) || E'\n'
FROM totals_readable
UNION ALL (
    SELECT E'=============================================================================================================\n' || 'pos:' || pos || E'\t total time: ' || total_time || ' (' || time_percent || ', CPU: ' || cpu_time_percent || ', IO: ' || io_time_percent || E')\t calls: ' || calls || ' (' || calls_percent || E'%)\t avg_time: ' || avg_time || 'ms (IO: ' || avg_io_time_percent || E')\t min/max exec time: ' || min_exec_time || 'ms / ' || max_exec_time || E'ms\n' || 'user: ' || username || E'\t db: ' || database || E'\t rows: ' || ROWS || ' (' || row_percent || '%)' || E'\t query:\n' || coalesce(query, 'unknown') || E'\n'
    FROM statements_readable
    ORDER BY pos
);