# Operational Store Assets

Bundle 2.0.0 introduced the Host-scoped CUSTOMER_MANAGED binding. Bundle 2.1.0
adds the Workflow-owned endpoint-resolution projection. Environment remains
runtime-instance routing metadata and is not part of database ownership.

The pinned bundle under `bundle/` is applied to all three local operational
databases declared by `operational-databases.tsv`:

| Host label | Database |
| --- | --- |
| `dev.lightapi.net` | `operations` |
| `dev.networknt.com` | `operations_networknt` |
| `dev.taiji.io` | `operations_taiji` |

`bootstrap-operational-databases.sh` is a one-shot, idempotent deployment
bootstrap. It verifies the original bundle checksums, renders only the database
identifier and role prefix for each target, applies the same ordered migrations,
and records an immutable database-local scope root. For these three default
databases, that scope root is the canonical Portal Host UUID so registration,
publication audience, and database identity can be checked end to end.

Each database has its own seven least-privilege login roles. Host-specific URL
files are generated under
`postgres-db/secrets/operational-hosts/<host-name>/`; credentials cannot
connect to either of the other operational databases.
`validate-operational-databases.sh` checks the three identities, migration
ledgers, schemas, role isolation, file permissions, and URL contracts.

Database creation belongs to deployment initialization. No background
provisioner, Docker socket mount, Portal worker token, or per-Host PostgreSQL
container is required. The ordered
`events/deltas/20260902-001-operational-store-default-registrations.json`
delta imports the canonical Orgs and Hosts before publishing all three default
version-2 registrations. Its zero nonces are allocated transactionally by the
event importer, and the delta ledger makes upgrades idempotent.
The 20260902-002 runtime-catalog delta assigns the complete operational-store
property set. The 20260902-004 publication-reconcile delta then updates each
registration at aggregate version 2 so those assignments are materialized even
when the registration event was projected before the catalog events.
The 20260902-003 API closure delta updates the Host command/query endpoint
inventory and deactivates the retired provisioning actions.
