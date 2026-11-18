-- Hermes worker registry and execution ledger. Installed by deploy.sql.

CREATE SCHEMA hermes;

-- One Hermes deployment. profile_key is stable even if a native profile is renamed.
CREATE TABLE hermes.profiles (
    profile_key text PRIMARY KEY CHECK (btrim(profile_key) <> ''),
    native_profile_name text NOT NULL UNIQUE CHECK (btrim(native_profile_name) <> ''),
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- workdir is resolved by the dispatcher on the Hermes host.
CREATE TABLE hermes.workspaces (
    target_id uuid PRIMARY KEY REFERENCES agent_zero.project_targets (id),
    workdir text NOT NULL CHECK (btrim(workdir) <> ''),
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE hermes.workspace_profiles (
    target_id uuid NOT NULL REFERENCES hermes.workspaces (target_id),
    profile_key text NOT NULL REFERENCES hermes.profiles (profile_key),
    enabled boolean NOT NULL DEFAULT true,
    PRIMARY KEY (target_id, profile_key)
);

ALTER TABLE orchestration.workflow_steps
    ADD CONSTRAINT workflow_steps_workspace_profile_fk
    FOREIGN KEY (target_id, profile_key)
    REFERENCES hermes.workspace_profiles (target_id, profile_key);

-- Reuse the run ID as the dispatch idempotency key when redelivering an attempt.
-- A retry creates a new run ID and increments attempt_no for the step.
CREATE TABLE hermes.runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    step_id uuid,
    target_id uuid NOT NULL,
    profile_key text NOT NULL,
    context_revision_id uuid NOT NULL,
    workdir text NOT NULL,
    native_profile_name text NOT NULL,
    attempt_no integer NOT NULL DEFAULT 1 CHECK (attempt_no > 0),
    native_session_id text,
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    input jsonb NOT NULL,
    claim_token uuid,
    claimed_at timestamptz,
    output jsonb,
    error jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    FOREIGN KEY (target_id, profile_key)
        REFERENCES hermes.workspace_profiles (target_id, profile_key),
    FOREIGN KEY (target_id, context_revision_id)
        REFERENCES agent_zero.context_revisions (target_id, id),
    UNIQUE (step_id, attempt_no),
    CHECK (step_id IS NOT NULL OR attempt_no = 1),
    CHECK (started_at >= created_at),
    CHECK (claimed_at >= started_at),
    CHECK (finished_at >= COALESCE(started_at, created_at)),
    CHECK (finished_at >= claimed_at),
    CHECK (status NOT IN ('running', 'succeeded') OR started_at IS NOT NULL),
    CHECK ((claimed_at IS NULL) = (claim_token IS NULL)),
    CHECK (status <> 'queued' OR claim_token IS NULL),
    CHECK (status <> 'running' OR claim_token IS NOT NULL),
    CHECK ((finished_at IS NOT NULL) = (status IN ('succeeded', 'failed', 'cancelled'))),
    CHECK (status <> 'failed' OR error IS NOT NULL)
);

-- Composite reference pins an orchestrated attempt to its step's configuration.
ALTER TABLE hermes.runs
    ADD FOREIGN KEY (step_id, target_id, profile_key, context_revision_id)
        REFERENCES orchestration.workflow_steps (id, target_id, profile_key, context_revision_id);

CREATE UNIQUE INDEX runs_one_active_attempt_per_step_idx
    ON hermes.runs (step_id)
    WHERE step_id IS NOT NULL AND status IN ('queued', 'running');

CREATE INDEX runs_queued_idx ON hermes.runs (created_at, id) WHERE status = 'queued';

CREATE INDEX runs_running_idx ON hermes.runs (claimed_at, id) WHERE status = 'running';
CREATE INDEX runs_workspace_profile_idx ON hermes.runs (target_id, profile_key);
CREATE INDEX runs_context_idx ON hermes.runs (target_id, context_revision_id);
CREATE INDEX workspace_profiles_profile_idx ON hermes.workspace_profiles (profile_key);

CREATE INDEX runs_session_idx
    ON hermes.runs (profile_key, native_session_id, created_at DESC)
    WHERE native_session_id IS NOT NULL;

CREATE TABLE hermes.run_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id uuid NOT NULL REFERENCES hermes.runs (id),
    event_type text NOT NULL CHECK (btrim(event_type) <> ''),
    payload jsonb NOT NULL DEFAULT '{}',
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX run_events_run_idx ON hermes.run_events (run_id, id);

-- Share route eligibility between enqueue and claim. A disabled route pauses
-- queued dispatches but does not prevent recording the outcome of a claimed run.
CREATE VIEW hermes.enabled_routes AS
SELECT mapping.target_id, mapping.profile_key, workspace.workdir, profile.native_profile_name
FROM hermes.workspace_profiles AS mapping
JOIN hermes.workspaces AS workspace USING (target_id)
JOIN hermes.profiles AS profile USING (profile_key)
JOIN agent_zero.project_targets AS target ON target.id = mapping.target_id
JOIN agent_zero.projects AS project ON project.id = target.project_id
WHERE mapping.enabled AND workspace.enabled AND profile.enabled
  AND target.archived_at IS NULL AND project.archived_at IS NULL;

CREATE FUNCTION hermes.pin_run_route()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    SELECT route.workdir, route.native_profile_name INTO NEW.workdir, NEW.native_profile_name
    FROM hermes.enabled_routes AS route
    WHERE route.target_id = NEW.target_id AND route.profile_key = NEW.profile_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hermes route is missing, disabled, or archived' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER run_pin_route BEFORE INSERT ON hermes.runs
    FOR EACH ROW EXECUTE FUNCTION hermes.pin_run_route();

CREATE FUNCTION hermes.log_run_enqueue()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    INSERT INTO hermes.run_events (run_id, event_type) VALUES (NEW.id, 'queued');
    RETURN NEW;
END;
$$;

CREATE TRIGGER run_log_enqueue AFTER INSERT ON hermes.runs
    FOR EACH ROW EXECUTE FUNCTION hermes.log_run_enqueue();

CREATE VIEW orchestration.ready_steps AS
SELECT step.id AS step_id, step.workflow_id, step.plan_revision, step.step_key,
       COALESCE(last_attempt.attempt_no, 0) + 1 AS attempt_no
FROM orchestration.workflow_steps AS step
JOIN orchestration.workflow_runs AS workflow ON workflow.id = step.workflow_id
   AND workflow.active_plan_revision = step.plan_revision AND workflow.status = 'running'
JOIN hermes.enabled_routes AS route ON route.target_id = step.target_id AND route.profile_key = step.profile_key
LEFT JOIN LATERAL (
    SELECT run.attempt_no FROM hermes.runs AS run WHERE run.step_id = step.id
    ORDER BY run.attempt_no DESC LIMIT 1
) AS last_attempt ON true
WHERE step.status = 'pending' AND COALESCE(last_attempt.attempt_no, 0) < step.max_attempts
  AND NOT EXISTS (
      SELECT 1 FROM orchestration.step_dependencies AS dependency
      JOIN orchestration.workflow_steps AS prerequisite ON prerequisite.id = dependency.prerequisite_step_id
      WHERE dependency.workflow_id = step.workflow_id AND dependency.plan_revision = step.plan_revision
        AND dependency.step_id = step.id AND prerequisite.status <> 'succeeded'
  );

CREATE FUNCTION orchestration.enqueue_step(p_step uuid, p_attempt integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    workflow_id uuid;
    step orchestration.workflow_steps;
    run_id uuid;
BEGIN
    SELECT s.workflow_id INTO workflow_id FROM orchestration.workflow_steps AS s WHERE s.id = p_step;
    PERFORM 1 FROM orchestration.workflow_runs WHERE id = workflow_id FOR NO KEY UPDATE;

    SELECT id INTO run_id FROM hermes.runs WHERE step_id = p_step AND attempt_no = p_attempt;
    IF FOUND THEN
        RETURN run_id;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM orchestration.ready_steps WHERE step_id = p_step AND attempt_no = p_attempt
    ) THEN
        RAISE EXCEPTION 'Step is not ready for the requested attempt' USING ERRCODE = '23514';
    END IF;

    SELECT * INTO STRICT step FROM orchestration.workflow_steps WHERE id = p_step;
    INSERT INTO hermes.runs (step_id, target_id, profile_key, context_revision_id, attempt_no, input)
    VALUES (step.id, step.target_id, step.profile_key, step.context_revision_id, p_attempt, step.input)
    RETURNING id INTO run_id;
    UPDATE orchestration.workflow_steps SET status = 'running' WHERE id = p_step;
    RETURN run_id;
END;
$$;

CREATE FUNCTION hermes.claim_run()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    claimed hermes.runs;
    dispatch jsonb;
    dispatched_at timestamptz;
BEGIN
    SELECT candidate.id INTO claimed.id
    FROM hermes.runs AS candidate
    JOIN hermes.enabled_routes AS route USING (target_id, profile_key)
    WHERE candidate.status = 'queued'
    ORDER BY candidate.created_at, candidate.id
    FOR UPDATE OF candidate SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    dispatched_at := clock_timestamp();
    UPDATE hermes.runs AS run SET status = 'running',
        claim_token = gen_random_uuid(),
        claimed_at = dispatched_at,
        started_at = COALESCE(run.started_at, dispatched_at)
    WHERE run.id = claimed.id
    RETURNING run.* INTO claimed;

    INSERT INTO hermes.run_events (run_id, event_type) VALUES (claimed.id, 'claimed');
    SELECT jsonb_build_object(
        'run_id', claimed.id, 'claim_token', claimed.claim_token, 'step_id', claimed.step_id,
        'target_id', claimed.target_id, 'profile_key', claimed.profile_key,
        'native_profile_name', claimed.native_profile_name, 'workdir', claimed.workdir,
        'context_revision_id', claimed.context_revision_id, 'context', revision.context_payload,
        'attempt_no', claimed.attempt_no, 'instructions', step.instructions, 'input', claimed.input
    ) INTO dispatch
    FROM agent_zero.context_revisions AS revision
    LEFT JOIN orchestration.workflow_steps AS step ON step.id = claimed.step_id
    WHERE revision.id = claimed.context_revision_id;
    RETURN dispatch;
END;
$$;

CREATE FUNCTION hermes.cancel_queued_run(p_run uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    cancelled hermes.runs;
    workflow_id uuid;
BEGIN
    SELECT step.workflow_id INTO workflow_id FROM hermes.runs AS run
    JOIN orchestration.workflow_steps AS step ON step.id = run.step_id WHERE run.id = p_run;
    IF FOUND THEN
        PERFORM 1 FROM orchestration.workflow_runs WHERE id = workflow_id FOR NO KEY UPDATE;
    END IF;
    UPDATE hermes.runs SET status = 'cancelled', finished_at = clock_timestamp()
    WHERE id = p_run AND status = 'queued' RETURNING * INTO cancelled;
    IF NOT FOUND THEN
        RETURN EXISTS (
            SELECT 1 FROM hermes.runs WHERE id = p_run AND status = 'cancelled' AND claim_token IS NULL
        );
    END IF;
    UPDATE orchestration.workflow_steps SET status = 'cancelled', finished_at = cancelled.finished_at
    WHERE id = cancelled.step_id;
    INSERT INTO hermes.run_events (run_id, event_type) VALUES (p_run, 'cancelled');
    RETURN true;
END;
$$;

CREATE FUNCTION hermes.finish_run(
    p_run uuid, p_claim uuid, p_status text, p_output jsonb DEFAULT NULL,
    p_error jsonb DEFAULT NULL, p_session text DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    attempt hermes.runs;
    workflow_id uuid;
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('succeeded', 'failed', 'cancelled')
       OR (p_status = 'failed' AND p_error IS NULL) THEN
        RAISE EXCEPTION 'Provide a terminal status and an error for failed attempts' USING ERRCODE = '23514';
    END IF;

    SELECT step.workflow_id INTO workflow_id FROM hermes.runs AS run
    JOIN orchestration.workflow_steps AS step ON step.id = run.step_id WHERE run.id = p_run;
    IF FOUND THEN
        PERFORM 1 FROM orchestration.workflow_runs WHERE id = workflow_id FOR NO KEY UPDATE;
    END IF;
    SELECT * INTO attempt FROM hermes.runs WHERE id = p_run FOR NO KEY UPDATE;
    IF NOT FOUND OR p_claim IS NULL OR attempt.claim_token IS DISTINCT FROM p_claim THEN
        RETURN false;
    END IF;
    IF attempt.status <> 'running' THEN
        RETURN attempt.status = p_status AND attempt.output IS NOT DISTINCT FROM p_output
            AND attempt.error IS NOT DISTINCT FROM p_error
            AND attempt.native_session_id IS NOT DISTINCT FROM p_session;
    END IF;

    UPDATE hermes.runs SET status = p_status, output = p_output, error = p_error,
        native_session_id = p_session, finished_at = clock_timestamp()
    WHERE id = p_run RETURNING * INTO attempt;
    UPDATE orchestration.workflow_steps AS step
    SET status = CASE WHEN p_status = 'failed' AND attempt.attempt_no < step.max_attempts
                      THEN 'pending' ELSE p_status END,
        finished_at = CASE WHEN p_status = 'failed' AND attempt.attempt_no < step.max_attempts
                           THEN NULL ELSE attempt.finished_at END
    WHERE step.id = attempt.step_id;
    INSERT INTO hermes.run_events (run_id, event_type) VALUES (p_run, p_status);
    RETURN true;
END;
$$;

-- Controller recovery after checking the native execution. Reuse the run ID,
-- retain the route snapshot, and invalidate the previous dispatcher's claim.
CREATE FUNCTION hermes.requeue_run(p_run uuid, p_claim uuid, p_reason text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'A reconciliation reason is required' USING ERRCODE = '23514';
    END IF;
    UPDATE hermes.runs SET status = 'queued', claim_token = NULL, claimed_at = NULL
    WHERE id = p_run AND status = 'running' AND claim_token = p_claim;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    INSERT INTO hermes.run_events (run_id, event_type, payload)
    VALUES (p_run, 'requeued', jsonb_build_object('reason', p_reason));
    RETURN true;
END;
$$;
