-- Agent Zero project registry and dispatch context. Installed by deploy.sql.

CREATE SCHEMA agent_zero;

CREATE TABLE agent_zero.projects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_key text NOT NULL CHECK (btrim(instance_key) <> ''),
    project_key text NOT NULL CHECK (btrim(project_key) <> ''),
    display_name text NOT NULL CHECK (btrim(display_name) <> ''),
    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    UNIQUE (instance_key, project_key),
    CHECK (archived_at >= created_at)
);

-- A target is the project-scoped identity of a lower-level Hermes workspace.
-- Its concrete Hermes configuration is registered in migration 03.
CREATE TABLE agent_zero.project_targets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES agent_zero.projects (id),
    target_key text NOT NULL CHECK (btrim(target_key) <> ''),
    context_policy jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(context_policy) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    UNIQUE (project_id, target_key),
    UNIQUE (project_id, id),
    CHECK (archived_at >= created_at)
);

-- Insert a new row for each approved snapshot.
-- Store only the selected, worker-facing context for this target.
CREATE TABLE agent_zero.context_revisions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    target_id uuid NOT NULL REFERENCES agent_zero.project_targets (id),
    source_revision text,
    context_payload jsonb NOT NULL CHECK (jsonb_typeof(context_payload) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (target_id, id)
);

CREATE FUNCTION agent_zero.reject_context_revision_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Context revisions are immutable. Insert a new revision.'
        USING ERRCODE = '23514';
END;
$$;

CREATE TRIGGER context_revision_immutable
    BEFORE UPDATE OR DELETE ON agent_zero.context_revisions
    FOR EACH ROW EXECUTE FUNCTION agent_zero.reject_context_revision_change();
