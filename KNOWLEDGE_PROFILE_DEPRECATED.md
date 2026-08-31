# Knowledge topology status

The retired clone/projector Knowledge service definitions have been replaced
by the canonical isolated database bootstrap and the snapshot-based API,
administration, and worker services.

This repository, `portal-config-loc/all-in-lt`, and `light-portal-install` all
use the canonical Knowledge DDL, a separate administration service and worker,
and recurring signed control snapshots. The services are part of each default
Compose application; no Knowledge profile is required.

The checked-in defaults use the same development Knowledge service token and
administration snapshot token as the other two development deployments.
`KNOWLEDGE_PORTAL_AUTHORIZATION` and `KNOWLEDGE_SNAPSHOT_AUTHORIZATION` may
override them when rotating credentials.
