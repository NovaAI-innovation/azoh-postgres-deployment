# Agent Zero and Hermes PostgreSQL deployment

Agent Zero owns requests, plan revisions, dependencies, and workflow outcomes. A trusted dispatcher claims queued work and calls Hermes. PostgreSQL keeps the queue, attempt history, and worker-facing context for one Hermes deployment per database.

## Schema assessment

| Migration | Responsibility | Changes |
| --- | --- | --- |
| `01_agent_zero.sql` | Projects, project targets, and approved context | Keeps project-scoped identities and makes context revisions immutable. |
| `02_orchestration.sql` | Requests, plan revisions, steps, and dependencies | Validates dependencies for cycles, seals activated plans, and checks workflow closeout against step outcomes. |
| `03_hermes.sql` | Route registry, queue, attempts, and events | Enforces readiness and retry limits, snapshots dispatch settings, and records attempt and step outcomes in one transaction. Claim tokens fence stale dispatchers after recovery. |

The original compound foreign keys already enforced project, target, context, and plan boundaries. The revised migrations retain those constraints and add indexes for foreign-key lookups, pending steps, queue claims, and unresolved dispatches.

## Install with Docker Compose

Create a local `.env` beside `docker-compose.yml` with `POSTGRES_PASSWORD` set to a strong administrator password. Keep this file out of source control. Optionally set `AZOH_POSTGRES_PORT` to change the host port from `55432`.

```sh
docker compose up -d --wait
docker compose exec -T postgres psql -X -U postgres -d azoh -f /opt/azoh/verify.sql
```

Run verification before writing Hermes runs. Host clients connect to `127.0.0.1:55432`. Other containers on the same Compose network connect to `postgres:5432`. Use the administrator to provision the separate application logins and grant the roles below.

Compose persists data in the `postgres_data` named volume. The official image runs the installer when it initializes an empty volume. `docker compose down` preserves the volume, and subsequent startups reuse its database. If the first install fails, inspect `docker compose logs postgres`. Correct the cause and start the container with `docker compose up -d`. If the three application schemas are absent, rerun the installer with `docker compose exec -T postgres psql -X -U postgres -d azoh -f /opt/azoh/deploy.sql`. [Official PostgreSQL image initialization guide](https://hub.docker.com/_/postgres)

## Install on an existing PostgreSQL server

Use PostgreSQL 15 or later, an empty application schema namespace, and a deployment account with database `CREATE` and permission to create the two group roles if they are absent. Use an owner without custom default grants to other application roles. The application logins should be separate from the deployment account. Run these commands from the package directory, using your usual libpq credentials.

```sh
createdb azoh
psql -X --dbname=azoh --file=deploy.sql
psql -X --dbname=azoh --file=verify.sql
```

For a pre-provisioned empty database, use its connection details in the two `psql` commands. `deploy.sql` applies all three migrations and access grants in one transaction and refuses to proceed if any target schema already exists. `verify.sql` assumes a database administrator able to assume both group roles and an isolated database with no Hermes runs. It rolls back its test data.

## Application logins

Grant the group roles to the existing application logins. Substitute the example login names.

```sql
GRANT azoh_controller TO agent_zero_service;
GRANT azoh_dispatcher TO hermes_dispatch_service;
```

The controller has access to project data, plans, and recovery operations. The dispatcher can claim work and report an outcome using its claim token. It receives the selected context for each claim through the function response. Both roles cover the entire database and assume trusted services within one deployment.

## Adapter contract

1. **Register a route.** Agent Zero inserts a project, a target, and a target-specific context revision, then registers the Hermes native profile, absolute host work directory, and workspace/profile mapping. Put only approved worker-facing data in `context_payload`. The database stores the path as supplied. The dispatcher validates the resolved path against its host configuration.
2. **Submit and plan.** Insert into `orchestration.workflow_runs` using a stable `request_key` per project. On a conflict, read the existing row and verify its request payload matches. Insert the plan revision, steps, and dependency edges. Call `orchestration.activate_plan(workflow_id, revision)` after Agent Zero accepts the plan. A newer plan can replace an active plan once its queued or claimed attempts are resolved. Superseded pending steps are cancelled and prior results remain available.
3. **Enqueue.** Read `orchestration.ready_steps` and call `orchestration.enqueue_step(step_id, attempt_no)` with the returned attempt number. Repeat the same pair after an ambiguous response to retrieve the same run ID. An outstanding attempt puts the step in `running` while the attempt itself is queued or claimed. A failed attempt reopens the step while its retry budget remains. Apply retry timing and backoff in Agent Zero before enqueueing again.
4. **Claim and execute.** The dispatcher calls `hermes.claim_run()` in a short transaction. SQL `NULL` means there is no claimable work. Commit the claim before calling Hermes. The response includes `run_id`, `claim_token`, the route snapshot, context, instructions, and input. Use the run UUID to correlate or deduplicate the native dispatch where the adapter supports it. Restrict access to claim tokens and keep them out of prompts and logs.
5. **Report and close.** Call `hermes.finish_run(run_id, claim_token, status, output, error, native_session_id)` with `succeeded`, `failed`, or `cancelled`. Supply an error for failures. The function returns `true` for an accepted result or an identical replay and `false` for a stale claim or conflicting completion. Agent Zero calls `orchestration.finish_workflow(workflow_id, status, output)` once its closeout conditions are met.

For a standalone Hermes run, the controller can insert a row into `hermes.runs` with a stable caller-generated `id`, the target, profile, context revision, and input. Its `step_id` stays null. Standalone instructions belong in `input`. Check the run by ID when recovering from an ambiguous insert response.

Use short transactions at PostgreSQL's default `READ COMMITTED` isolation. If PostgreSQL aborts a transaction due to a deadlock or serialization conflict, retry the whole transaction. Call the database functions from the Agent Zero and Hermes adapters using bound parameters. This package contains the database and its contract. Adapter changes and native Hermes connectivity require integration in the services that will call it.

## Operations and recovery

The controller can inspect queue state and dispatch history with these queries.

```sql
SELECT status, count(*) FROM hermes.runs GROUP BY status ORDER BY status;

SELECT id, step_id, profile_key, claimed_at
FROM hermes.runs
WHERE status = 'running' AND claimed_at < now() - interval '30 minutes'
ORDER BY claimed_at;
```

Adjust the inspection threshold to the expected run duration. For an interrupted dispatcher, locate the native execution by run ID and reconcile its outcome first. Use `finish_run` with the current token if the result is known. Use `hermes.requeue_run(run_id, claim_token, reason)` when replay of the same run is safe. Requeue generates a fresh token on the next claim and retains the original route snapshot. Uncertain native outcomes stay in the ledger for reconciliation. PostgreSQL cannot make the external Hermes call exactly once.

Use `hermes.cancel_queued_run(run_id)` for an unclaimed run. For claimed work, stop or reconcile native execution before recording cancellation. Resolve outstanding runs before replacing a plan or cancelling its workflow. Disabling a route pauses queued claims. Any claim already made can still report its outcome. If a route's native name or work directory changes, a queued run retains the values captured at enqueue.

## Existing databases and rollback

The files are a fresh-install baseline. For a database already using the original migrations, take a backup, inventory the applied schema and data, and prepare a forward migration against a restored copy. The installer rejects existing target schemas.

A failed install rolls back automatically. Before installing into an existing database with unrelated schemas, capture a database backup using `pg_dump --format=custom --dbname=DATABASE --file=before-azoh.dump`. If a successful installation needs to be reversed, stop application writes, restore the chosen backup into a separate database with `pg_restore --exit-on-error --dbname=RESTORE_DB before-azoh.dump`, validate it, and repoint the application. Preserve the deployed database and any newer work for reconciliation. The two group roles and their memberships are cluster-wide and are administered separately from a database restore.
