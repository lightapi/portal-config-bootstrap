# Operational Database Secrets

The one-shot operational database bootstrap creates permission-restricted,
Host-specific service credentials and URL files below
`operational-hosts/<host-name>/`. Each Host directory contains URLs for Agent,
execution, Workflow, A2A, Gateway, audit, and artifact runtimes. The URL role and
database name are unique to that Host's operational database.

Existing top-level `operations` URL files remain the compatibility input for
`dev.lightapi.net`; the bootstrap copies their credential contracts into the
Host-specific layout. Secret files must not be committed, printed, or stored in
Config Server values.
