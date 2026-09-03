# Private instance event deltas

The current signed `events.zip` baseline contains the canonical `dev.lightapi.net`, `dev.networknt.com`, and `dev.taiji.io` organizations, Hosts, and operational-store registrations. They must not be exported as private deltas. Startup still evaluates checksum-pinned release deltas because a version-pinned baseline can predate a delta; the release ledger and superseded list prevent duplicate application.

Customer-created Hosts must not be added to the checked-in `events/deltas` directory. Export them as event arrays into the ignored directory:

```text
data/private-event-deltas/
├── manifest.json
├── 001-customer-host.json
└── 002-customer-config.json
```

The manifest is ordered and checksum-pins every private file:

```json
{
  "format": "lightapi.portal-instance-event-deltas",
  "formatVersion": 1,
  "instanceId": "customer-installation-1",
  "eventDeltas": [
    {
      "id": "001-customer-host",
      "file": "001-customer-host.json",
      "sha256": "<64 lowercase hexadecimal characters>"
    }
  ]
}
```

After copying exported event arrays into the directory, generate the ordered manifest and checksums with `./scripts/build-instance-event-delta-manifest.sh customer-installation-1`. The importer rejects missing, extra, invalid, or checksum-drifted files. Applied private deltas are recorded separately in `portal_instance_event_delta_t`, keyed by `instanceId` and delta ID, so their names cannot collide with release deltas.

The normal restart/install flow imports this directory after the signed baseline and release upgrades. A versioned `EVENT_IMPORTER_IMAGE` must be available whenever the manifest contains entries. To keep the files elsewhere, set `PORTAL_INSTANCE_EVENT_DELTA_DIR`; to keep the manifest elsewhere, set `PORTAL_INSTANCE_EVENT_DELTA_MANIFEST`. Set `PORTAL_SKIP_INSTANCE_EVENT_DELTAS=true` to skip only private deltas. Back up the entire private directory because it is deliberately excluded from Git and release deployment cleanup.
