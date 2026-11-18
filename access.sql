-- Run as part of deploy.sql. These group roles are shared by databases in the cluster.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'azoh_controller') THEN
        CREATE ROLE azoh_controller NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'azoh_dispatcher') THEN
        CREATE ROLE azoh_dispatcher NOLOGIN;
    END IF;
END;
$$;

REVOKE ALL ON SCHEMA agent_zero, orchestration, hermes FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA agent_zero, orchestration, hermes FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA agent_zero, orchestration, hermes FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA agent_zero, orchestration, hermes FROM PUBLIC;

GRANT USAGE ON SCHEMA agent_zero, orchestration, hermes TO azoh_controller;
GRANT SELECT ON ALL TABLES IN SCHEMA agent_zero, orchestration, hermes TO azoh_controller;
GRANT INSERT (instance_key, project_key, display_name), UPDATE (display_name, archived_at)
    ON agent_zero.projects TO azoh_controller;
GRANT INSERT (project_id, target_key, context_policy), UPDATE (context_policy, archived_at)
    ON agent_zero.project_targets TO azoh_controller;
GRANT INSERT (target_id, source_revision, context_payload)
    ON agent_zero.context_revisions TO azoh_controller;
GRANT INSERT (id, project_id, request_key, request_payload)
    ON orchestration.workflow_runs TO azoh_controller;
GRANT INSERT (workflow_id, revision, rationale)
    ON orchestration.plan_revisions TO azoh_controller;
GRANT INSERT (id, workflow_id, project_id, plan_revision, step_key, target_id,
              context_revision_id, profile_key, instructions, input, max_attempts),
      UPDATE (step_key, target_id, context_revision_id, profile_key, instructions, input, max_attempts),
      DELETE ON orchestration.workflow_steps TO azoh_controller;
GRANT INSERT, DELETE ON orchestration.step_dependencies TO azoh_controller;
GRANT INSERT (profile_key, native_profile_name, enabled), UPDATE (native_profile_name, enabled)
    ON hermes.profiles TO azoh_controller;
GRANT INSERT (target_id, workdir, enabled), UPDATE (workdir, enabled)
    ON hermes.workspaces TO azoh_controller;
GRANT INSERT (target_id, profile_key, enabled), UPDATE (enabled)
    ON hermes.workspace_profiles TO azoh_controller;
GRANT INSERT (id, target_id, profile_key, context_revision_id, input)
    ON hermes.runs TO azoh_controller;
GRANT EXECUTE ON FUNCTION orchestration.activate_plan(uuid, integer),
    orchestration.finish_workflow(uuid, text, jsonb), orchestration.enqueue_step(uuid, integer),
    hermes.cancel_queued_run(uuid), hermes.requeue_run(uuid, uuid, text),
    hermes.finish_run(uuid, uuid, text, jsonb, jsonb, text) TO azoh_controller;

GRANT USAGE ON SCHEMA hermes TO azoh_dispatcher;
GRANT EXECUTE ON FUNCTION hermes.claim_run(), hermes.finish_run(uuid, uuid, text, jsonb, jsonb, text)
    TO azoh_dispatcher;
