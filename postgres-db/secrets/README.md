# Operational Database Secrets

`prepare-operational-secret.sh` creates separate development Agent, execution,
Workflow, A2A, Gateway, audit-publisher, and artifact-runtime credentials plus
their database URL files and the private `a2a-authorized-context-key` here with
owner-only permissions. The Compose stack mounts the URLs under `/run/secrets`;
their content must not be committed, printed, or stored in Config Server
values.
