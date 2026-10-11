-- ============================================================
-- ChronoRel++ PostgreSQL Extension
-- Version: 1.0
-- ============================================================

-- ChronoRel++ internal registry

CREATE TABLE chrono_registry (
    registory_id SERIAL PRIMARY KEY,
    table_name VARCHAR(100) UNIQUE NOT NULL,
    primary_key_column VARCHAR(100) NOT NULL,
    history_table_name VARCHAR(100) NOT NULL,
    temporal_enabled BOOLEAN DEFAULT TRUE,
    registered_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);


CREATE TABLE chrono_config (
    config_id SERIAL PRIMARY KEY,
    config_key VARCHAR(100) UNIQUE NOT NULL,
    config_value TEXT NOT NULL,
    description TEXT
);

INSERT INTO chrono_config
(
    config_key,
    config_value,
    description
)
VALUES
(
    'versioning',
    'enabled',
    'Automatically maintain historical versions'
),
(
    'audit_logging',
    'enabled',
    'Record temporal data changes'
),
(
    'restoration',
    'enabled',
    'Allow non-destructive restoration of historical versions'
);


CREATE TABLE chrono_audit_log (
    audit_id BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(100) NOT NULL,
    record_key JSONB NOT NULL,
    version INTEGER NOT NULL,
    operation VARCHAR(20) NOT NULL,
    changed_by VARCHAR(100) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (
        operation IN ('INSERT', 'UPDATE', 'DELETE', 'RESTORE')
    )
);

-- ============================================================
-- Helper: Build JSONB delta between two row snapshots
-- ============================================================

CREATE OR REPLACE FUNCTION public.chrono_build_delta(
    p_old JSONB,
    p_new JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_result JSONB := '{}'::JSONB;
    v_key TEXT;
    v_old_value JSONB;
    v_new_value JSONB;
BEGIN
    FOR v_key IN
        SELECT jsonb_object_keys(p_new)
        UNION
        SELECT jsonb_object_keys(p_old)
    LOOP
        v_old_value := p_old -> v_key;
        v_new_value := p_new -> v_key;

        IF v_old_value IS DISTINCT FROM v_new_value THEN
            v_result :=
                v_result ||
                jsonb_build_object(
                    v_key,
                    jsonb_build_object(
                        'old', v_old_value,
                        'new', v_new_value
                    )
                );
        END IF;
    END LOOP;

    RETURN v_result;
END;
$function$;


-- ============================================================
-- Helper: Remove ChronoRel++ metadata from row JSON
-- ============================================================

CREATE OR REPLACE FUNCTION public.chrono_clean_json(
    p_row JSONB
)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT p_row
           - 'chrono_version'
           - 'chrono_valid_from'
           - 'chrono_valid_to';
$function$;


-- ============================================================
-- Helper: Write an entry to the ChronoRel++ audit log
-- ============================================================

CREATE OR REPLACE FUNCTION public.chrono_write_audit(
    p_table_name TEXT,
    p_record_key JSONB,
    p_version INTEGER,
    p_operation TEXT,
    p_changed_by TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO chrono_audit_log (
        table_name,
        record_key,
        version,
        operation,
        changed_by
    )
    VALUES (
        p_table_name,
        p_record_key,
        p_version,
        p_operation,
        p_changed_by
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.chrono_version_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_history_table TEXT;
    v_pk_column TEXT;
    v_record_key JSONB;
    v_old_json JSONB;
    v_new_json JSONB;
    v_delta JSONB;
    v_next_version INTEGER;
    v_now TIMESTAMPTZ := CURRENT_TIMESTAMP;
    v_audit_operation TEXT;
BEGIN

    -- Get ChronoRel++ configuration
    SELECT history_table_name, primary_key_column
    INTO v_history_table, v_pk_column
    FROM chrono_registry
    WHERE table_name = TG_TABLE_NAME
      AND temporal_enabled = TRUE;

    IF v_history_table IS NULL THEN
        RAISE EXCEPTION
            'Table "%" is not enabled for ChronoRel++',
            TG_TABLE_NAME;
    END IF;


    ----------------------------------------------------------------
    -- INSERT
    ----------------------------------------------------------------
    IF TG_OP = 'INSERT' THEN

        v_new_json := chrono_clean_json(to_jsonb(NEW));

        v_record_key :=
            jsonb_build_object(
                v_pk_column,
                v_new_json -> v_pk_column
            );

        -- Continue version numbering if this record existed before.
        EXECUTE format(
            'SELECT COALESCE(MAX(chrono_version), 0) + 1
             FROM %I
             WHERE chrono_record_key = $1',
            v_history_table
        )
        INTO v_next_version
        USING v_record_key;

        -- Close any previously open history version.
        EXECUTE format(
            'UPDATE %I
             SET chrono_valid_to = $1
             WHERE chrono_record_key = $2
               AND chrono_valid_to IS NULL',
            v_history_table
        )
        USING v_now, v_record_key;

        NEW.chrono_version := v_next_version;
        NEW.chrono_valid_from := v_now;

        -- Store history
        EXECUTE format(
            'INSERT INTO %I
            (
                chrono_record_key,
                chrono_snapshot,
                chrono_delta,
                chrono_valid_from,
                chrono_valid_to,
                chrono_version,
                chrono_operation,
                chrono_changed_by
            )
            VALUES
            (
                $1::jsonb,
                $2::jsonb,
                NULL::jsonb,
                $3::timestamptz,
                NULL::timestamptz,
                $4::integer,
                $5::varchar,
                $6::varchar
            )',
            v_history_table
        )
        USING
            v_record_key,
            v_new_json,
            v_now,
            v_next_version,
            'INSERT',
            CURRENT_USER;

        -- Restore is internally an INSERT, but audit records user intent.
        IF current_setting('chronorel.restore', true) = 'true' THEN
            v_audit_operation := 'RESTORE';
        ELSE
            v_audit_operation := 'INSERT';
        END IF;

        PERFORM chrono_write_audit(
            TG_TABLE_NAME,
            v_record_key,
            v_next_version,
            v_audit_operation,
            CURRENT_USER
        );

        RETURN NEW;

    END IF;


    ----------------------------------------------------------------
    -- UPDATE
    ----------------------------------------------------------------
    IF TG_OP = 'UPDATE' THEN

        v_old_json := chrono_clean_json(to_jsonb(OLD));
        v_new_json := chrono_clean_json(to_jsonb(NEW));

        v_delta := chrono_build_delta(
            v_old_json,
            v_new_json
        );

        v_next_version := OLD.chrono_version + 1;
        NEW.chrono_version := v_next_version;
        NEW.chrono_valid_from := v_now;

        v_record_key :=
            jsonb_build_object(
                v_pk_column,
                v_new_json -> v_pk_column
            );

        -- Close previous version
        EXECUTE format(
            'UPDATE %I
             SET chrono_valid_to = $1
             WHERE chrono_record_key = $2
               AND chrono_valid_to IS NULL',
            v_history_table
        )
        USING v_now, v_record_key;

        -- Store new version
        EXECUTE format(
            'INSERT INTO %I
            (
                chrono_record_key,
                chrono_snapshot,
                chrono_delta,
                chrono_valid_from,
                chrono_valid_to,
                chrono_version,
                chrono_operation,
                chrono_changed_by
            )
            VALUES
            (
                $1::jsonb,
                $2::jsonb,
                $3::jsonb,
                $4::timestamptz,
                NULL::timestamptz,
                $5::integer,
                $6::varchar,
                $7::varchar
            )',
            v_history_table
        )
        USING
            v_record_key,
            v_new_json,
            v_delta,
            v_now,
            v_next_version,
            'UPDATE',
            CURRENT_USER;

        -- Restore can also update an existing record.
        IF current_setting('chronorel.restore', true) = 'true' THEN
            v_audit_operation := 'RESTORE';
        ELSE
            v_audit_operation := 'UPDATE';
        END IF;

        PERFORM chrono_write_audit(
            TG_TABLE_NAME,
            v_record_key,
            v_next_version,
            v_audit_operation,
            CURRENT_USER
        );

        RETURN NEW;

    END IF;


    ----------------------------------------------------------------
    -- DELETE
    ----------------------------------------------------------------
    IF TG_OP = 'DELETE' THEN

        v_old_json := chrono_clean_json(to_jsonb(OLD));

        v_record_key :=
            jsonb_build_object(
                v_pk_column,
                v_old_json -> v_pk_column
            );

        v_next_version := OLD.chrono_version + 1;

        -- Close previous active version
        EXECUTE format(
            'UPDATE %I
             SET chrono_valid_to = $1
             WHERE chrono_record_key = $2
               AND chrono_valid_to IS NULL',
            v_history_table
        )
        USING v_now, v_record_key;

        -- Record deletion
        EXECUTE format(
            'INSERT INTO %I
            (
                chrono_record_key,
                chrono_snapshot,
                chrono_delta,
                chrono_valid_from,
                chrono_valid_to,
                chrono_version,
                chrono_operation,
                chrono_changed_by
            )
            VALUES
            (
                $1::jsonb,
                $2::jsonb,
                NULL::jsonb,
                $3::timestamptz,
                NULL::timestamptz,
                $4::integer,
                $5::varchar,
                $6::varchar
            )',
            v_history_table
        )
        USING
            v_record_key,
            v_old_json,
            v_now,
            v_next_version,
            'DELETE',
            CURRENT_USER;

        PERFORM chrono_write_audit(
            TG_TABLE_NAME,
            v_record_key,
            v_next_version,
            'DELETE',
            CURRENT_USER
        );

        RETURN OLD;

    END IF;

    RETURN NULL;

END;
$function$;


CREATE OR REPLACE FUNCTION public.chrono_enable_temporal(p_table_name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_column TEXT;
    v_history_table TEXT;
    v_exists BOOLEAN;
BEGIN

    -- 1. Check that the target table exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = p_table_name
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Table "%" does not exist', p_table_name;
    END IF;


    -- 2. Find the primary-key column
    SELECT kcu.column_name
    INTO v_pk_column
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.table_schema = kcu.table_schema
    WHERE tc.table_schema = 'public'
      AND tc.table_name = p_table_name
      AND tc.constraint_type = 'PRIMARY KEY'
    LIMIT 1;

    IF v_pk_column IS NULL THEN
        RAISE EXCEPTION
            'Table "%" does not have a primary key',
            p_table_name;
    END IF;


    -- 3. Generate history-table name
    v_history_table := p_table_name || '_history';


    -- 4. Add temporal metadata to original table
    EXECUTE format(
        'ALTER TABLE %I
         ADD COLUMN IF NOT EXISTS chrono_valid_from TIMESTAMPTZ
         DEFAULT CURRENT_TIMESTAMP',
        p_table_name
    );

    EXECUTE format(
        'ALTER TABLE %I
         ADD COLUMN IF NOT EXISTS chrono_version INTEGER
         DEFAULT 1',
        p_table_name
    );


    -- 5. Create ChronoRel++ JSONB history table
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            chrono_history_id BIGSERIAL PRIMARY KEY,
            chrono_record_key JSONB NOT NULL,
            chrono_snapshot JSONB,
            chrono_delta JSONB,
            chrono_valid_from TIMESTAMPTZ NOT NULL,
            chrono_valid_to TIMESTAMPTZ,
            chrono_version INTEGER NOT NULL,
            chrono_operation VARCHAR(20) NOT NULL,
            chrono_changed_by VARCHAR(100) NOT NULL,
            CHECK (chrono_operation IN (''INSERT'', ''UPDATE'', ''DELETE''))
        )',
        v_history_table
    );


    -- 6. Register the table with ChronoRel++
    INSERT INTO chrono_registry
    (
        table_name,
        primary_key_column,
        history_table_name
    )
    VALUES
    (
        p_table_name,
        v_pk_column,
        v_history_table
    )
    ON CONFLICT (table_name)
    DO UPDATE SET
        primary_key_column = EXCLUDED.primary_key_column,
        history_table_name = EXCLUDED.history_table_name,
        temporal_enabled = TRUE;


    -- 7. Create the row-level versioning trigger
    EXECUTE format(
        'DROP TRIGGER IF EXISTS chrono_versioning_trigger ON %I',
        p_table_name
    );

    EXECUTE format(
        'CREATE TRIGGER chrono_versioning_trigger
         BEFORE INSERT OR UPDATE OR DELETE
         ON %I
         FOR EACH ROW
         EXECUTE FUNCTION chrono_version_trigger()',
        p_table_name
    );


    RETURN format(
        'ChronoRel++ enabled for table "%s". History table: "%s". Primary key: "%s".',
        p_table_name,
        v_history_table,
        v_pk_column
    );

END;
$function$;


CREATE OR REPLACE FUNCTION public.chrono_disable_temporal(p_table_name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- Check that the table exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = p_table_name
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'Table "%" does not exist',
            p_table_name;
    END IF;

    -- Check that ChronoRel++ knows about this table
    IF NOT EXISTS (
        SELECT 1
        FROM chrono_registry
        WHERE table_name = p_table_name
    ) THEN
        RAISE EXCEPTION
            'Table "%" is not registered with ChronoRel++',
            p_table_name;
    END IF;

    -- Disable temporal tracking in the registry
    UPDATE chrono_registry
    SET temporal_enabled = FALSE
    WHERE table_name = p_table_name;

    -- Remove the row-level tracking trigger.
    -- History table and existing history are intentionally preserved.
    EXECUTE format(
        'DROP TRIGGER IF EXISTS chrono_versioning_trigger ON %I',
        p_table_name
    );

    RETURN format(
        'ChronoRel++ temporal tracking disabled for table "%s". Existing history preserved.',
        p_table_name
    );

END;
$function$;



CREATE OR REPLACE FUNCTION public.chrono_history(p_table_name text, p_record_id text)
 RETURNS TABLE(chrono_history_id bigint, chrono_record_key jsonb, chrono_version integer, chrono_operation character varying, chrono_valid_from timestamp with time zone, chrono_valid_to timestamp with time zone, chrono_snapshot jsonb, chrono_delta jsonb, chrono_changed_by character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_history_table TEXT;
    v_pk_column TEXT;
BEGIN

    -- Find the table's ChronoRel++ registration
    SELECT
        history_table_name,
        primary_key_column
    INTO
        v_history_table,
        v_pk_column
    FROM chrono_registry
    WHERE table_name = p_table_name
      AND temporal_enabled = TRUE;

    -- Make sure the table is registered
    IF v_history_table IS NULL THEN
        RAISE EXCEPTION
            'Table "%" is not registered with ChronoRel++',
            p_table_name;
    END IF;

    -- Dynamically query the correct history table and PK
    RETURN QUERY EXECUTE format(
        'SELECT
            chrono_history_id,
            chrono_record_key,
            chrono_version,
            chrono_operation,
            chrono_valid_from,
            chrono_valid_to,
            chrono_snapshot,
            chrono_delta,
            chrono_changed_by
         FROM %I
         WHERE chrono_record_key ->> %L = $1
         ORDER BY chrono_version',
        v_history_table,
        v_pk_column
    )
    USING p_record_id;

END;
$function$;


CREATE OR REPLACE FUNCTION public.chrono_as_of(p_table_name text, p_record_id text, p_timestamp timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_history_table TEXT;
    v_pk_column TEXT;
    v_result JSONB;
BEGIN
    -- Get ChronoRel++ metadata
    SELECT history_table_name, primary_key_column
    INTO v_history_table, v_pk_column
    FROM chrono_registry
    WHERE table_name = p_table_name;

    IF v_history_table IS NULL THEN
        RAISE EXCEPTION
            'Table "%" is not registered with ChronoRel++',
            p_table_name;
    END IF;

    -- Find the version that was active at the requested time.
    -- DELETE versions are excluded because after deletion
    -- the record should no longer exist.
    EXECUTE format(
        'SELECT chrono_snapshot
         FROM %I
         WHERE chrono_record_key ->> %L = $1
           AND chrono_operation <> ''DELETE''
           AND chrono_valid_from <= $2
           AND (
               chrono_valid_to > $2
               OR chrono_valid_to IS NULL
           )
         ORDER BY chrono_version DESC
         LIMIT 1',
        v_history_table,
        v_pk_column
    )
    INTO v_result
    USING p_record_id, p_timestamp;

    RETURN v_result;
END;
$function$;


CREATE OR REPLACE PROCEDURE public.chrono_restore(IN p_table_name text, IN p_record_id text, IN p_version integer)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_history_table TEXT;
    v_pk_column TEXT;
    v_snapshot JSONB;
    v_exists BOOLEAN;
    v_columns TEXT;
    v_values TEXT;
BEGIN
    SELECT history_table_name, primary_key_column
    INTO v_history_table, v_pk_column
    FROM chrono_registry
    WHERE table_name = p_table_name
      AND temporal_enabled = TRUE;

    IF v_history_table IS NULL THEN
        RAISE EXCEPTION
            'Table "%" is not registered with ChronoRel++',
            p_table_name;
    END IF;

    EXECUTE format(
        'SELECT chrono_snapshot
         FROM %I
         WHERE chrono_record_key ->> %L = $1
           AND chrono_version = $2
           AND chrono_operation <> ''DELETE''
         LIMIT 1',
        v_history_table,
        v_pk_column
    )
    INTO v_snapshot
    USING p_record_id, p_version;

    IF v_snapshot IS NULL THEN
        RAISE EXCEPTION
            'Version % for record % does not exist or is a DELETE version',
            p_version,
            p_record_id;
    END IF;

    /*
     * Tell the version trigger that the following INSERT/UPDATE
     * is being performed by chrono_restore().
     *
     * Transaction-local setting: automatically disappears
     * when the transaction ends.
     */
    PERFORM set_config(
        'chronorel.restore',
        'true',
        true
    );

    EXECUTE format(
        'SELECT EXISTS (
            SELECT 1
            FROM %I
            WHERE %I::TEXT = $1
        )',
        p_table_name,
        v_pk_column
    )
    INTO v_exists
    USING p_record_id;

    IF v_exists THEN

        SELECT string_agg(
            format(
                '%I = ($1 ->> %L)::%s',
                column_name,
                column_name,
                format_type(a.atttypid, a.atttypmod)
            ),
            ', '
        )
        INTO v_columns
        FROM pg_attribute a
        JOIN information_schema.columns c
          ON c.table_name = p_table_name
         AND c.column_name = a.attname
         AND c.table_schema = 'public'
        WHERE a.attrelid = p_table_name::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attname NOT IN ('chrono_version','chrono_valid_from')
          AND a.attname <> v_pk_column;

        EXECUTE format(
            'UPDATE %I
             SET %s
             WHERE %I::TEXT = $2',
            p_table_name,
            v_columns,
            v_pk_column
        )
        USING v_snapshot, p_record_id;

    ELSE

        SELECT string_agg(
            format('%I', column_name),
            ', '
        )
        INTO v_columns
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = p_table_name
          AND column_name NOT IN (
              'chrono_version',
              'chrono_valid_from'
          );

        SELECT string_agg(
            format(
                '($1 ->> %L)::%s',
                column_name,
                format_type(
                    (
                        SELECT atttypid
                        FROM pg_attribute
                        WHERE attrelid = p_table_name::regclass
                          AND attname = information_schema.columns.column_name
                          AND attnum > 0
                          AND NOT attisdropped
                    ),
                    (
                        SELECT atttypmod
                        FROM pg_attribute
                        WHERE attrelid = p_table_name::regclass
                          AND attname = information_schema.columns.column_name
                          AND attnum > 0
                          AND NOT attisdropped
                    )
                )
            ),
            ', '
        )
        INTO v_values
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = p_table_name
          AND column_name NOT IN (
              'chrono_version',
              'chrono_valid_from'
          );

        EXECUTE format(
            'INSERT INTO %I (%s)
             SELECT %s',
            p_table_name,
            v_columns,
            v_values
        )
        USING v_snapshot;

    END IF;
END;
$procedure$;



CREATE OR REPLACE FUNCTION public.chrono_schema_monitor()
 RETURNS event_trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_command RECORD;
    v_table_name TEXT;
    v_pk_count INTEGER;
    v_pk_column TEXT;
BEGIN

    FOR v_command IN
        SELECT *
        FROM pg_event_trigger_ddl_commands()
    LOOP

        IF v_command.command_tag = 'CREATE TABLE'
           AND v_command.schema_name = 'public'
        THEN

            v_table_name := v_command.object_identity;

            v_table_name :=
                regexp_replace(
                    v_table_name,
                    '^public\.',
                    ''
                );

            -- Ignore ChronoRel++ internal history tables.
            IF v_table_name LIKE '%_history' THEN
                CONTINUE;
            END IF;

            -- Ignore ChronoRel++ internal tables.
            IF v_table_name IN (
                'chrono_registry',
                'chrono_config',
                'chrono_audit_log'
            ) THEN
                CONTINUE;
            END IF;

            /*
             * Count the number of columns participating
             * in the primary key.
             */
            SELECT COUNT(*)
            INTO v_pk_count
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
             AND tc.table_name = kcu.table_name
            WHERE tc.table_schema = 'public'
              AND tc.table_name = v_table_name
              AND tc.constraint_type = 'PRIMARY KEY';

            -- No primary key.
            IF v_pk_count = 0 THEN

                RAISE NOTICE
                    'ChronoRel++: table "%" detected, but no primary key was found. Temporal tracking skipped.',
                    v_table_name;

                CONTINUE;

            END IF;

            -- Composite primary key.
            IF v_pk_count > 1 THEN

                RAISE NOTICE
                    'ChronoRel++: table "%" has a composite primary key (% columns). Composite primary keys are not supported in the MVP. Temporal tracking skipped.',
                    v_table_name,
                    v_pk_count;

                CONTINUE;

            END IF;

            -- Single-column primary key.
            SELECT kcu.column_name
            INTO v_pk_column
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
             AND tc.table_name = kcu.table_name
            WHERE tc.table_schema = 'public'
              AND tc.table_name = v_table_name
              AND tc.constraint_type = 'PRIMARY KEY'
            LIMIT 1;

            RAISE NOTICE
                'ChronoRel++: automatically enabling temporal tracking for table "%".',
                v_table_name;

            PERFORM chrono_enable_temporal(v_table_name);

        END IF;

    END LOOP;

END;
$function$;


-- ============================================================
-- ChronoRel++ automatic schema monitoring
-- ============================================================

CREATE EVENT TRIGGER chrono_schema_event_trigger
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE')
EXECUTE FUNCTION chrono_schema_monitor();


