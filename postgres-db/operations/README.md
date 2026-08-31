# Operational Store Assets

`bin/` and `bundle/` are byte-identical copies of the canonical versioned assets
from `light-fabric/crates/operational-store`. Do not edit staged SQL here.
Regenerate the deployment bundle from the owning crate and pass the
cross-repository parity and lifecycle gates instead.

Phase 7 also stages `operational-store-provisioner.sh`,
`provision-dev-dedicated.sh`, and `rotate-dev-dedicated-credentials.sh` from
the owning crate. Run the provisioner as a separate privileged process, not in
the PostgreSQL entrypoint and not in the Host command request. It requires
permission-restricted Portal URL/token files, an existing Docker network, and
an external binding-secret root. Only `DEV_DEDICATED` is enabled; deactivation
and decommission stop the binding container while preserving its data volume.
