-- Run as an administrator on an isolated deployment with no Hermes runs.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL statement_timeout = '15s';
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    project uuid;
    target uuid;
    context_id uuid;
    workflow uuid := gen_random_uuid();
    first_step uuid := gen_random_uuid();
    second_step uuid := gen_random_uuid();
    replacement_step uuid := gen_random_uuid();
    attempt uuid;
    token uuid;
    dispatch jsonb;
BEGIN
    IF EXISTS (SELECT 1 FROM hermes.runs) THEN
        RAISE EXCEPTION 'Use verify.sql only on an isolated deployment with no Hermes runs';
    END IF;
    ASSERT NOT has_table_privilege('azoh_dispatcher', 'agent_zero.context_revisions', 'SELECT');
    ASSERT NOT has_table_privilege('azoh_dispatcher', 'hermes.runs', 'SELECT');
    ASSERT NOT has_function_privilege('azoh_dispatcher', 'hermes.requeue_run(uuid,uuid,text)', 'EXECUTE');
    ASSERT NOT has_column_privilege('azoh_controller', 'hermes.runs', 'status', 'UPDATE');

    SET LOCAL ROLE azoh_controller;
    INSERT INTO agent_zero.projects (instance_key, project_key, display_name)
    VALUES ('verify', workflow::text, 'Verification') RETURNING id INTO project;
    INSERT INTO agent_zero.project_targets (project_id, target_key)
    VALUES (project, 'main') RETURNING id INTO target;
    INSERT INTO agent_zero.context_revisions (target_id, context_payload)
    VALUES (target, '{"fixture":true}') RETURNING id INTO context_id;
    INSERT INTO hermes.profiles (profile_key, native_profile_name)
    VALUES (workflow::text, workflow::text);
    INSERT INTO hermes.workspaces (target_id, workdir) VALUES (target, '/verification');
    INSERT INTO hermes.workspace_profiles (target_id, profile_key) VALUES (target, workflow::text);

    INSERT INTO orchestration.workflow_runs (id, project_id, request_key, request_payload)
    VALUES (workflow, project, 'request-1', '{}');
    INSERT INTO orchestration.plan_revisions (workflow_id, revision) VALUES (workflow, 1), (workflow, 2);
    INSERT INTO orchestration.workflow_steps (
        id, workflow_id, project_id, plan_revision, step_key, target_id, context_revision_id,
        profile_key, instructions, max_attempts
    ) VALUES
        (first_step, workflow, project, 1, 'first', target, context_id, workflow::text, 'First', 2),
        (second_step, workflow, project, 1, 'second', target, context_id, workflow::text, 'Second', 1),
        (replacement_step, workflow, project, 2, 'replacement', target, context_id, workflow::text, 'Replace', 1);
    INSERT INTO orchestration.step_dependencies VALUES
        (workflow, 1, second_step, first_step), (workflow, 1, first_step, second_step);
    BEGIN
        PERFORM orchestration.activate_plan(workflow, 1);
        RAISE EXCEPTION 'Expected cycle rejection';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    DELETE FROM orchestration.step_dependencies WHERE step_id = first_step;
    PERFORM orchestration.activate_plan(workflow, 1);
    BEGIN
        UPDATE orchestration.workflow_steps SET instructions = 'Changed' WHERE id = first_step;
        RAISE EXCEPTION 'Expected sealed plan rejection';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    ASSERT EXISTS (SELECT 1 FROM orchestration.ready_steps WHERE step_id = first_step AND attempt_no = 1);
    ASSERT NOT EXISTS (SELECT 1 FROM orchestration.ready_steps WHERE step_id = second_step);
    BEGIN
        PERFORM orchestration.enqueue_step(second_step, 1);
        RAISE EXCEPTION 'Expected dependency rejection';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    attempt := orchestration.enqueue_step(first_step, 1);
    ASSERT orchestration.enqueue_step(first_step, 1) = attempt;
    BEGIN
        PERFORM orchestration.activate_plan(workflow, 2);
        RAISE EXCEPTION 'Expected active attempt to prevent replacement';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE hermes.workspaces SET enabled = false, workdir = '/new-directory' WHERE target_id = target;
    SET LOCAL ROLE azoh_dispatcher;
    ASSERT hermes.claim_run() IS NULL;
    SET LOCAL ROLE azoh_controller;
    UPDATE hermes.workspaces SET enabled = true WHERE target_id = target;

    SET LOCAL ROLE azoh_dispatcher;
    dispatch := hermes.claim_run();
    token := (dispatch->>'claim_token')::uuid;
    ASSERT (dispatch->>'run_id')::uuid = attempt;
    ASSERT dispatch->>'workdir' = '/verification';
    ASSERT dispatch->>'instructions' = 'First';
    ASSERT dispatch->'context' = '{"fixture": true}';
    ASSERT hermes.claim_run() IS NULL;
    SET LOCAL ROLE azoh_controller;
    ASSERT hermes.requeue_run(attempt, token, 'Verified that native execution never started');
    SET LOCAL ROLE azoh_dispatcher;
    dispatch := hermes.claim_run();
    ASSERT (dispatch->>'run_id')::uuid = attempt;
    ASSERT NOT hermes.finish_run(attempt, token, 'succeeded');
    token := (dispatch->>'claim_token')::uuid;
    ASSERT hermes.finish_run(attempt, token, 'failed', NULL, '{"code":"fixture"}');
    ASSERT hermes.finish_run(attempt, token, 'failed', NULL, '{"code":"fixture"}');

    SET LOCAL ROLE azoh_controller;
    ASSERT orchestration.enqueue_step(first_step, 1) = attempt;
    ASSERT EXISTS (SELECT 1 FROM orchestration.ready_steps WHERE step_id = first_step AND attempt_no = 2);
    BEGIN
        PERFORM orchestration.enqueue_step(first_step, 3);
        RAISE EXCEPTION 'Expected retry limit rejection';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    attempt := orchestration.enqueue_step(first_step, 2);
    SET LOCAL ROLE azoh_dispatcher;
    dispatch := hermes.claim_run();
    ASSERT dispatch->>'workdir' = '/new-directory';
    ASSERT hermes.finish_run(attempt, (dispatch->>'claim_token')::uuid, 'succeeded', '{"ok":true}', NULL, 'fixture');

    SET LOCAL ROLE azoh_controller;
    ASSERT EXISTS (SELECT 1 FROM orchestration.ready_steps WHERE step_id = second_step);
    PERFORM orchestration.activate_plan(workflow, 2);
    ASSERT (SELECT status = 'cancelled' FROM orchestration.workflow_steps WHERE id = second_step);
    attempt := orchestration.enqueue_step(replacement_step, 1);
    ASSERT hermes.cancel_queued_run(attempt);
    ASSERT hermes.cancel_queued_run(attempt);
    PERFORM orchestration.finish_workflow(workflow, 'failed', '{"reason":"fixture"}');
    PERFORM orchestration.finish_workflow(workflow, 'failed', '{"reason":"fixture"}');
    ASSERT (SELECT status = 'failed' FROM orchestration.workflow_runs WHERE id = workflow);

    INSERT INTO hermes.runs (target_id, profile_key, context_revision_id, input)
    VALUES (target, workflow::text, context_id, '{}') RETURNING id INTO attempt;
    SET LOCAL ROLE azoh_dispatcher;
    dispatch := hermes.claim_run();
    ASSERT (dispatch->>'run_id')::uuid = attempt AND dispatch->>'step_id' IS NULL;
    ASSERT hermes.finish_run(attempt, (dispatch->>'claim_token')::uuid, 'succeeded');

    SET LOCAL ROLE azoh_controller;
    INSERT INTO orchestration.workflow_runs (project_id, request_key, request_payload)
    VALUES (project, 'request-2', '{}') RETURNING id INTO workflow;
    INSERT INTO orchestration.plan_revisions (workflow_id, revision) VALUES (workflow, 1);
    INSERT INTO orchestration.workflow_steps (
        workflow_id, project_id, plan_revision, step_key, target_id,
        context_revision_id, profile_key, instructions
    ) VALUES (
        workflow, project, 1, 'only', target, context_id, dispatch->>'profile_key', 'Only'
    ) RETURNING id INTO first_step;
    PERFORM orchestration.activate_plan(workflow, 1);
    attempt := orchestration.enqueue_step(first_step, 1);
    SET LOCAL ROLE azoh_dispatcher;
    dispatch := hermes.claim_run();
    ASSERT (dispatch->>'run_id')::uuid = attempt;
    ASSERT hermes.finish_run(attempt, (dispatch->>'claim_token')::uuid, 'succeeded');
    SET LOCAL ROLE azoh_controller;
    PERFORM orchestration.finish_workflow(workflow, 'succeeded');
    ASSERT (SELECT status = 'succeeded' FROM orchestration.workflow_runs WHERE id = workflow);
END;
$$;
ROLLBACK;
\echo AZOH deployment verification passed
