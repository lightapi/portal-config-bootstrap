Provide these runtime-only files before enabling the `knowledge` Compose profile:

- `knowledge-database-url`
- `knowledge-worker-database-url`
- `knowledge-projector-database-url`
- `configserver-event-read-url`
- `agent-delegation-secret`
- `knowledge-query-cache-key`
- `knowledge-heartbeat-secret`
- `knowledge-portal-authorization`
- `knowledge-connector-authorization` (Phase 2 enterprise sources only)

Protected embedding qualification also requires separate `kb_index` and
`kb_query` workload credentials. Point `embeddingAuthorizationFile` in the
worker and API configs at their respective runtime-only files when
`deterministicPilot` is set to `false`; do not reuse a standard model lane.
Embedding migrations additionally keep `migrationDeterministicPilot: false`.
The `kb_index` lane must enforce `x-light-maximum-billed-cost-micros` and
return `x-light-billed-cost-micros`; missing or over-ceiling evidence is
rejected after the worker reserves the approved budget.

Do not commit their values. The API, worker, and projector URLs target the
`knowledge` database. `configserver-event-read-url` targets `configserver`
with the read-only projector identity. The three identities use the roles
created by the Knowledge schema.

`knowledge-query-cache-key` must contain at least 32 random bytes and be
independent of `agent-delegation-secret`; rotate the two on separate schedules.

The `agent-delegation-secret` value must match
`LIGHT_AGENT_DELEGATION_SECRET`. The bearer token stored in
`knowledge-portal-authorization` must have a `sub` included in
`KNOWLEDGE_WORKLOAD_PRINCIPALS`; the local default principal is
both `light-knowledge-worker` and `light-knowledge` during the rollback
window. Promotion acknowledgements do not require an
end-user tenant or platform-admin role: the allowlisted workload identity and
the exact pending-outbox generation, pointer, and evidence digest authorize the
operation.
