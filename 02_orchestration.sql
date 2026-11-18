-- Durable workflow plans and state. Installed by deploy.sql.

CREATE SCHEMA orchestration;

CREATE TABLE orchestration.workflow_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES agent_zero.projects (id),
    request_key text NOT NULL CHECK (btrim(request_key) <> ''),
    request_payload jsonb NOT NULL,
    status text NOT NULL DEFAULT 'planning'
        CHECK (status IN ('planning', 'running', 'succeeded', 'failed', 'cancelled')),
    output jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    UNIQUE (project_id, request_key),
    UNIQUE (id, project_id),
    CHECK ((finished_at IS NOT NULL) = (status IN ('succeeded', 'failed', 'cancelled'))),
    CHECK (finished_at >= created_at)
);

CREATE TABLE orchestration.plan_revisions (
    workflow_id uuid NOT NULL REFERENCES orchestration.workflow_runs (id),
    revision integer NOT NULL CHECK (revision > 0),
    rationale text,
    created_at timestamptz NOT NULL DEFAULT now(),
    sealed_at timestamptz CHECK (sealed_at >= created_at),
    PRIMARY KEY (workflow_id, revision)
);

-- NULL means no plan has been accepted yet.
ALTER TABLE orchestration.workflow_runs
    ADD COLUMN active_plan_revision integer,
    ADD FOREIGN KEY (id, active_plan_revision)
        REFERENCES orchestration.plan_revisions (workflow_id, revision),
    ADD CHECK (status NOT IN ('running', 'succeeded', 'failed') OR active_plan_revision IS NOT NULL),
    ADD CHECK (status <> 'planning' OR active_plan_revision IS NULL);

CREATE TABLE orchestration.workflow_steps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_id uuid NOT NULL,
    project_id uuid NOT NULL,
    plan_revision integer NOT NULL,
    step_key text NOT NULL CHECK (btrim(step_key) <> ''),
    target_id uuid NOT NULL,
    context_revision_id uuid NOT NULL,
    profile_key text NOT NULL CHECK (btrim(profile_key) <> ''),
    instructions text NOT NULL CHECK (btrim(instructions) <> ''),
    input jsonb NOT NULL DEFAULT '{}',
    max_attempts integer NOT NULL DEFAULT 1 CHECK (max_attempts > 0),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'cancelled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    FOREIGN KEY (workflow_id, project_id)
        REFERENCES orchestration.workflow_runs (id, project_id),
    FOREIGN KEY (workflow_id, plan_revision)
        REFERENCES orchestration.plan_revisions (workflow_id, revision),
    FOREIGN KEY (project_id, target_id)
        REFERENCES agent_zero.project_targets (project_id, id),
    FOREIGN KEY (target_id, context_revision_id)
        REFERENCES agent_zero.context_revisions (target_id, id),
    UNIQUE (workflow_id, plan_revision, step_key),
    UNIQUE (workflow_id, plan_revision, id),
    UNIQUE (id, target_id, profile_key, context_revision_id),
    CHECK ((finished_at IS NOT NULL) = (status IN ('succeeded', 'failed', 'cancelled'))),
    CHECK (finished_at >= created_at)
);

CREATE TABLE orchestration.step_dependencies (
    workflow_id uuid NOT NULL,
    plan_revision integer NOT NULL,
    step_id uuid NOT NULL,
    prerequisite_step_id uuid NOT NULL,
    PRIMARY KEY (workflow_id, plan_revision, step_id, prerequisite_step_id),
    FOREIGN KEY (workflow_id, plan_revision, step_id)
        REFERENCES orchestration.workflow_steps (workflow_id, plan_revision, id),
    FOREIGN KEY (workflow_id, plan_revision, prerequisite_step_id)
        REFERENCES orchestration.workflow_steps (workflow_id, plan_revision, id),
    CHECK (step_id <> prerequisite_step_id)
);

CREATE INDEX step_dependencies_prerequisite_idx
    ON orchestration.step_dependencies (workflow_id, plan_revision, prerequisite_step_id);

CREATE INDEX workflow_steps_pending_idx
    ON orchestration.workflow_steps (workflow_id, plan_revision, created_at)
    WHERE status = 'pending';

CREATE INDEX workflow_steps_workspace_profile_idx
    ON orchestration.workflow_steps (target_id, profile_key);

CREATE INDEX workflow_steps_context_idx
    ON orchestration.workflow_steps (target_id, context_revision_id);

-- Serialize edits to draft plans with activation. Runtime status changes
-- do not use this trigger and are made only through the workflow API.
CREATE FUNCTION orchestration.require_draft_plan()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    plan_workflow uuid;
    plan_number integer;
BEGIN
    IF TG_OP = 'DELETE' THEN
        plan_workflow := OLD.workflow_id;
        plan_number := OLD.plan_revision;
    ELSE
        plan_workflow := NEW.workflow_id;
        plan_number := NEW.plan_revision;
    END IF;

    UPDATE orchestration.workflow_runs SET status = status
    WHERE id = plan_workflow AND status IN ('planning', 'running');
    IF NOT FOUND OR EXISTS (
        SELECT 1 FROM orchestration.plan_revisions
        WHERE workflow_id = plan_workflow AND revision = plan_number AND sealed_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Only drafts of open workflows can be edited' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER workflow_step_draft
    BEFORE INSERT OR DELETE OR UPDATE OF target_id, context_revision_id, profile_key,
        step_key, instructions, input, max_attempts ON orchestration.workflow_steps
    FOR EACH ROW EXECUTE FUNCTION orchestration.require_draft_plan();

CREATE TRIGGER step_dependency_draft
    BEFORE INSERT OR DELETE ON orchestration.step_dependencies
    FOR EACH ROW EXECUTE FUNCTION orchestration.require_draft_plan();

CREATE FUNCTION orchestration.activate_plan(p_workflow uuid, p_revision integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    workflow orchestration.workflow_runs;
BEGIN
    SELECT * INTO workflow FROM orchestration.workflow_runs
    WHERE id = p_workflow FOR NO KEY UPDATE;
    IF NOT FOUND OR workflow.status NOT IN ('planning', 'running') THEN
        RAISE EXCEPTION 'Workflow is missing or closed' USING ERRCODE = '23514';
    END IF;
    IF workflow.active_plan_revision = p_revision THEN
        RETURN;
    END IF;
    IF p_revision IS NULL OR p_revision <= workflow.active_plan_revision OR NOT EXISTS (
        SELECT 1 FROM orchestration.plan_revisions
        WHERE workflow_id = p_workflow AND revision = p_revision AND sealed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Select an unsealed plan revision newer than the active revision' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM orchestration.workflow_steps
        WHERE workflow_id = p_workflow AND plan_revision = workflow.active_plan_revision AND status = 'running'
    ) THEN
        RAISE EXCEPTION 'Resolve active attempts before replacing a plan' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM orchestration.workflow_steps WHERE workflow_id = p_workflow AND plan_revision = p_revision
    ) THEN
        RAISE EXCEPTION 'Plan must contain at least one step' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        WITH RECURSIVE paths(step_id, prerequisite_step_id) AS (
            SELECT step_id, prerequisite_step_id FROM orchestration.step_dependencies
            WHERE workflow_id = p_workflow AND plan_revision = p_revision
            UNION
            SELECT paths.step_id, d.prerequisite_step_id
            FROM paths JOIN orchestration.step_dependencies AS d ON d.step_id = paths.prerequisite_step_id
            WHERE d.workflow_id = p_workflow AND d.plan_revision = p_revision
        )
        SELECT 1 FROM paths WHERE step_id = prerequisite_step_id
    ) THEN
        RAISE EXCEPTION 'Plan contains a dependency cycle' USING ERRCODE = '23514';
    END IF;

    UPDATE orchestration.workflow_steps SET status = 'cancelled', finished_at = clock_timestamp()
    WHERE workflow_id = p_workflow AND plan_revision = workflow.active_plan_revision AND status = 'pending';
    UPDATE orchestration.plan_revisions SET sealed_at = clock_timestamp()
    WHERE workflow_id = p_workflow AND revision = p_revision;
    UPDATE orchestration.workflow_runs SET active_plan_revision = p_revision, status = 'running'
    WHERE id = p_workflow;
END;
$$;

CREATE FUNCTION orchestration.finish_workflow(p_workflow uuid, p_status text, p_output jsonb DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    workflow orchestration.workflow_runs;
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('succeeded', 'failed', 'cancelled') THEN
        RAISE EXCEPTION 'Expected a terminal workflow status' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO workflow FROM orchestration.workflow_runs
    WHERE id = p_workflow FOR NO KEY UPDATE;
    IF workflow.status = p_status AND workflow.output IS NOT DISTINCT FROM p_output THEN
        RETURN;
    END IF;
    IF NOT FOUND OR workflow.status NOT IN ('planning', 'running') THEN
        RAISE EXCEPTION 'Workflow is missing or closed' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM orchestration.workflow_steps WHERE workflow_id = p_workflow
        AND plan_revision = workflow.active_plan_revision AND status = 'running'
    ) THEN
        RAISE EXCEPTION 'Resolve active attempts before closing the workflow' USING ERRCODE = '23514';
    END IF;
    IF p_status = 'succeeded' AND (
        workflow.active_plan_revision IS NULL OR EXISTS (
            SELECT 1 FROM orchestration.workflow_steps WHERE workflow_id = p_workflow
            AND plan_revision = workflow.active_plan_revision AND status <> 'succeeded'
        )
    ) THEN
        RAISE EXCEPTION 'All active plan steps must succeed before the workflow can succeed' USING ERRCODE = '23514';
    END IF;
    IF p_status = 'failed' AND NOT EXISTS (
        SELECT 1 FROM orchestration.workflow_steps WHERE workflow_id = p_workflow
        AND plan_revision = workflow.active_plan_revision AND status IN ('failed', 'cancelled')
    ) THEN
        RAISE EXCEPTION 'An active plan step must fail or be cancelled before the workflow can fail' USING ERRCODE = '23514';
    END IF;

    UPDATE orchestration.workflow_steps SET status = 'cancelled', finished_at = clock_timestamp()
    WHERE workflow_id = p_workflow AND plan_revision = workflow.active_plan_revision AND status = 'pending';
    UPDATE orchestration.workflow_runs SET status = p_status, output = p_output, finished_at = clock_timestamp()
    WHERE id = p_workflow;
END;
$$;
