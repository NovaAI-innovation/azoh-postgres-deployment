\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_setting('server_version_num')::integer < 150000 THEN
        RAISE EXCEPTION 'PostgreSQL 15 or later is required';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('agent_zero', 'orchestration', 'hermes')) THEN
        RAISE EXCEPTION 'Deployment requires the agent_zero, orchestration, and hermes schemas to be absent';
    END IF;
END;
$$;

\ir 01_agent_zero.sql
\ir 02_orchestration.sql
\ir 03_hermes.sql
\ir access.sql
COMMIT;
