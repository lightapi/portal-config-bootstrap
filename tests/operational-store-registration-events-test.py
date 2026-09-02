#!/usr/bin/env python3
"""Validate the canonical Host export and default operational-store registrations."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import uuid


ROOT = Path(__file__).resolve().parents[1]
DELTA = ROOT / "events/deltas/20260902-001-operational-store-default-registrations.json"
CATALOG_DELTA = ROOT / "events/deltas/20260902-002-operational-store-runtime-catalog-v2.json"
API_CLOSURE_DELTA = ROOT / "events/deltas/20260902-003-operational-storage-api-closure.json"
PUBLICATION_RECONCILE_DELTA = ROOT / "events/deltas/20260902-004-operational-store-publication-reconcile.json"
MANIFEST = ROOT / "postgres-db/operations/operational-databases.tsv"
if not MANIFEST.exists():
    MANIFEST = ROOT / "all-in-lt/postgres-db/operations/operational-databases.tsv"
INIT_SQL = ROOT / "postgres-db/init.sql"
if not INIT_SQL.exists():
    INIT_SQL = ROOT / "all-in-lt/postgres-db/init.sql"

EXPECTED = {
    "dev.lightapi.net": ("01964b05-552a-7c4b-9184-6857e7f3dc5f", "operations", "01a06356-a4aa-7528-838e-dfbbe90ec959", "sha256:79a39f6ff78c336d6ac9b0dc711115750bf22be954c584fa836930150e3db09e"),
    "dev.networknt.com": ("01a04864-b507-74dd-962a-d1e26769a3b4", "operations_networknt", "01a06356-a4ab-787b-9c0b-0320f6786463", "sha256:42a1d0a8ce60f42d8cdf51e60a7481984c69a1474a35f494deee0489c36c5f65"),
    "dev.taiji.io": ("01a06288-ceec-7de6-85b1-ed12d4dd4732", "operations_taiji", "01a06356-a4ac-7cd9-b5a0-2a38b39fdc73", "sha256:cd851be3e6932eeb735bc1dde8673042ade42398c41fc1a5c0ccebe5dea350cb"),
}
DIGEST_FIELDS = (
    "bindingId", "contractVersion", "credentialGeneration", "credentialReference",
    "credentialSource", "engine", "expectedDatabase", "hostId",
    "minimumSchemaGeneration", "port", "serverHost", "tlsMode",
)
EXPORTED_EVENT_IDS = {
    "01a05fcd-3f95-7f94-aa4a-83a2718b78f2",
    "01a05fcd-3f95-7f9e-aa4b-62b06542372f",
    "01a06288-cef4-75c4-ae8d-38afe82ed8f6",
    "01a05fcd-3f95-7fba-aa4c-c384994b588d",
    "01a05fcd-3f95-7fc8-aa4d-7244544d7fec",
    "01a06288-cef5-71b3-91a4-717e1892c832",
}


def fail(message: str) -> None:
    raise AssertionError(message)


def load_manifest() -> dict[str, tuple[str, str, str, str]]:
    mappings: dict[str, tuple[str, str, str, str]] = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        database, fqdn, host_id, binding_id, binding_digest = line.split("\t")
        mappings[fqdn] = (host_id, database, binding_id, binding_digest)
    return mappings


def main() -> int:
    events = json.loads(DELTA.read_text(encoding="utf-8"))
    if not isinstance(events, list) or len(events) != 9:
        fail("canonical delta must contain exactly six Host/Org events and three registrations")
    if [event["type"] for event in events] != (
        ["OrgCreatedEvent"] * 3
        + ["HostCreatedEvent"] * 3
        + ["OperationalStoreBindingRegisteredEvent"] * 3
    ):
        fail("dependencies must be ordered Org, Host, then registration")
    if {event["id"] for event in events[:6]} != EXPORTED_EVENT_IDS:
        fail("canonical Org/Host event identifiers drifted from the reviewed local export")
    if load_manifest() != EXPECTED:
        fail("operational database manifest does not use the canonical Host UUIDs")
    init_sql = INIT_SQL.read_text(encoding="utf-8")
    for required_sql in (
        "contract_version bigint DEFAULT 1 NOT NULL",
        "operational_store_binding_active_host_v2_uk",
        "customer-managed-registration-v2",
    ):
        if required_sql not in init_sql:
            fail(f"clean-install schema is missing {required_sql}")

    exported_hosts: dict[str, str] = {}
    for event in events[3:6]:
        data = event["data"]
        fqdn = f'{data["subDomain"]}.{data["domain"]}'
        if event["subject"] != data["hostId"]:
            fail(f"Host subject mismatch for {fqdn}")
        exported_hosts[fqdn] = data["hostId"]
    if exported_hosts != {fqdn: value[0] for fqdn, value in EXPECTED.items()}:
        fail("Host export does not match the canonical FQDN-to-UUID mapping")

    generated_ids: set[str] = set()
    for event in events[6:]:
        data = event["data"]
        host_id = data["hostId"]
        fqdn = next((name for name, value in EXPECTED.items() if value[0] == host_id), None)
        if fqdn is None:
            fail(f"registration uses an unknown Host UUID: {host_id}")
        database = EXPECTED[fqdn][1]
        if event["host"] != host_id or data["targetHostId"] != host_id:
            fail(f"publication audience mismatch for {fqdn}")
        expected_fields = {
            "contractVersion": 2,
            "scopeKind": "HOST",
            "engine": "POSTGRESQL",
            "serverHost": "postgres",
            "port": 5432,
            "expectedDatabase": database,
            "tlsMode": "DISABLE",
            "credentialSource": "MOUNTED_FILE",
            "credentialReference": "/run/secrets/operational-database-url",
            "minimumSchemaGeneration": 2,
            "credentialGeneration": 1,
            "lifecycleState": "REGISTERED",
            "active": True,
            "published": True,
            "aggregateVersion": 0,
            "newAggregateVersion": 1,
        }
        for field, expected in expected_fields.items():
            if data.get(field) != expected:
                fail(f"{fqdn} {field} mismatch: {data.get(field)!r} != {expected!r}")
        canonical = json.dumps(
            {field: data[field] for field in DIGEST_FIELDS},
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        expected_digest = "sha256:" + hashlib.sha256(canonical).hexdigest()
        if data["bindingDigest"] != expected_digest:
            fail(f"binding digest mismatch for {fqdn}")
        if (data["bindingId"], data["bindingDigest"]) != EXPECTED[fqdn][2:]:
            fail(f"runtime manifest binding identity mismatch for {fqdn}")
        if event["subject"] != data["bindingId"] or event["aggregateversion"] != 1:
            fail(f"registration stream identity/version mismatch for {fqdn}")
        if event.get("commandkind") != "CREATE" or event.get("entityscope") != "HOST":
            fail(f"registration event metadata mismatch for {fqdn}")
        generated_ids.update((event["id"], data["bindingId"]))

    if len(generated_ids) != 6:
        fail("generated registration identifiers are not unique")
    for identifier in generated_ids:
        parsed = uuid.UUID(identifier)
        if parsed.version != 7 or parsed.variant != uuid.RFC_4122:
            fail(f"generated identifier is not RFC 4122 UUID v7: {identifier}")
    if any(str(event.get("nonce")) != "0" for event in events):
        fail("portable event deltas must use the importer-allocated nonce sentinel")

    catalog = json.loads(CATALOG_DELTA.read_text(encoding="utf-8"))
    expected_catalog = {
        "contractVersion": ("integer", "2"),
        "serviceOwner": ("string", "light-gateway"),
        "schema": ("string", "gateway_ops"),
        "expectedDatabase": ("string", "operations"),
        "serverHost": ("string", "postgres"),
        "port": ("integer", "5432"),
        "tlsMode": ("string", "DISABLE"),
    }
    expected_deployer = {
        "operationalStore.contractVersion": ("integer", "2"),
        "operationalStore.bindingId": ("string", "00000000-0000-0000-0000-000000000000"),
        "operationalStore.bindingDigest": ("string", "sha256:" + "0" * 64),
        "operationalStore.hostId": ("string", "00000000-0000-0000-0000-000000000000"),
        "operationalStore.environment": ("string", "dev"),
        "operationalStore.serviceOwner": ("string", "light-deployer"),
        "operationalStore.schema": ("string", "operational_meta"),
        "operationalStore.expectedDatabase": ("string", "operations"),
        "operationalStore.minimumSchemaGeneration": ("integer", "2"),
        "operationalStore.databaseUrlFile": ("string", "/run/secrets/operational-database-url"),
        "operationalStore.credentialGeneration": ("integer", "1"),
        "operationalStore.serverHost": ("string", "postgres"),
        "operationalStore.port": ("integer", "5432"),
        "operationalStore.tlsMode": ("string", "DISABLE"),
    }
    expected_endpoint_properties = {
        "operationalStore.serverHost": ("string", "postgres"),
        "operationalStore.port": ("integer", "5432"),
        "operationalStore.tlsMode": ("string", "DISABLE"),
    }
    expected_config_ids = {
        "agent": "01a03ece-c1d9-7772-87b7-e875f691202d",
        "workflow": "01a036de-4754-7454-b6ee-60b33c27cdbd",
        "a2a": "01a050e9-7e07-76de-bb5e-a8af8bf1627b",
        "gateway-evidence": "01a050e9-7e08-74c9-bd75-f5ecf8d05e25",
        "deployer": "bc21af8a-2159-58eb-a079-edd49e5880a3",
    }
    expected_product_versions = {
        "agent": "019e979b-ff25-7e99-ad98-8cc1dfd3fdbf",
        "a2a": "019e979b-ff25-7e99-ad98-8cc1dfd3fdbf",
        "workflow": "019e979e-5184-7696-8721-36383630521b",
        "gateway-evidence": "019e979d-dfd3-7af8-a0e3-885697ab7166",
        "deployer": "019e979d-4a03-7b2c-a27d-6e7c3c1d3a79",
    }
    expected_mapping_counts = {
        (EXPECTED["dev.lightapi.net"][0], "agent"): 3,
        (EXPECTED["dev.lightapi.net"][0], "workflow"): 14,
        (EXPECTED["dev.lightapi.net"][0], "a2a"): 14,
        (EXPECTED["dev.lightapi.net"][0], "gateway-evidence"): 16,
        (EXPECTED["dev.lightapi.net"][0], "deployer"): 14,
        (EXPECTED["dev.networknt.com"][0], "agent"): 18,
        (EXPECTED["dev.networknt.com"][0], "workflow"): 14,
        (EXPECTED["dev.networknt.com"][0], "a2a"): 14,
        (EXPECTED["dev.networknt.com"][0], "gateway-evidence"): 16,
    }
    if not isinstance(catalog, list) or len(catalog) != 153:
        fail("version-2 runtime catalog delta must contain 30 properties and 123 mappings")
    property_events = [event for event in catalog
                       if event["type"] == "ConfigPropertyCreatedEvent"]
    mapping_events = [event for event in catalog
                      if event["type"] == "ProductVersionConfigPropertyCreatedEvent"]
    if len(property_events) != 30 or len(mapping_events) != 123:
        fail("runtime catalog property/mapping event counts are incomplete")
    catalog_ids: set[str] = set()
    new_properties: dict[tuple[str, str], str] = {}
    for event in property_events:
        data = event["data"]
        name = data["propertyName"]
        config_name = data.get("configName")
        if config_name == "gateway-evidence":
            expected = expected_catalog.get(name)
        elif config_name == "deployer":
            expected = expected_deployer.get(name)
        elif config_name in {"agent", "workflow", "a2a"}:
            expected = expected_endpoint_properties.get(name)
        else:
            fail(f"unexpected runtime catalog parent for {name}")
        if expected is None:
            fail(f"unexpected runtime catalog property {config_name}.{name}")
        if data.get("configId") != expected_config_ids[config_name]:
            fail(f"runtime catalog config ID mismatch for {name}")
        if (data.get("valueType"), data.get("propertyValue")) != expected:
            fail(f"runtime catalog value contract mismatch for {name}")
        if event["subject"] != data["propertyId"] or event["aggregateversion"] != 1:
            fail(f"runtime catalog stream identity/version mismatch for {name}")
        if str(event.get("nonce")) != "0":
            fail(f"runtime catalog event must use the importer nonce sentinel for {name}")
        catalog_ids.update((event["id"], data["propertyId"]))
        new_properties[(config_name, name)] = data["propertyId"]

    mapping_counts: dict[tuple[str, str], int] = {}
    mapped_property_ids: dict[tuple[str, str], set[str]] = {}
    config_by_id = {value: key for key, value in expected_config_ids.items()}
    for event in mapping_events:
        data = event["data"]
        config_name = config_by_id.get(data.get("configId"))
        key = (data.get("hostId"), config_name)
        if config_name is None or key not in expected_mapping_counts:
            fail(f"unexpected product-version mapping parent: {key}")
        if data.get("productVersionId") != expected_product_versions[config_name]:
            fail(f"product-version mapping mismatch for {key}")
        expected_subject = (f'{data["hostId"]}|{data["productVersionId"]}|'
                            f'{data["propertyId"]}')
        if event["subject"] != expected_subject or event["aggregateversion"] != 1:
            fail(f"product-version mapping stream mismatch for {key}")
        mapping_counts[key] = mapping_counts.get(key, 0) + 1
        mapped_property_ids.setdefault(key, set()).add(data["propertyId"])
        catalog_ids.add(event["id"])
    if mapping_counts != expected_mapping_counts:
        fail(f"operational-store product-version mapping coverage drifted: {mapping_counts}")
    for (config_name, _), property_id in new_properties.items():
        required_hosts = [EXPECTED["dev.lightapi.net"][0]]
        if config_name != "deployer":
            required_hosts.append(EXPECTED["dev.networknt.com"][0])
        for host_id in required_hosts:
            if property_id not in mapped_property_ids[(host_id, config_name)]:
                fail(f"new {config_name} property is not assigned for Host {host_id}")
    if len(catalog_ids) != len(catalog) + len(property_events):
        fail("runtime catalog event and property identifiers are not unique")
    for identifier in catalog_ids:
        parsed = uuid.UUID(identifier)
        if parsed.version != 7 or parsed.variant != uuid.RFC_4122:
            fail(f"runtime catalog identifier is not RFC 4122 UUID v7: {identifier}")

    reconcile_events = json.loads(PUBLICATION_RECONCILE_DELTA.read_text(encoding="utf-8"))
    registrations_by_subject = {event["subject"]: event for event in events[6:]}
    if not isinstance(reconcile_events, list) or len(reconcile_events) != 3:
        fail("publication reconcile delta must contain one update per Host registration")
    reconcile_ids: set[str] = set()
    for event in reconcile_events:
        original = registrations_by_subject.get(event.get("subject"))
        if original is None:
            fail(f"publication reconcile uses an unknown binding: {event.get('subject')}")
        if event.get("type") != "OperationalStoreBindingUpdatedEvent":
            fail("publication reconcile must use the registration update event")
        if event.get("host") != original["host"] or event.get("user") != original["user"]:
            fail(f"publication reconcile authority mismatch for {event['subject']}")
        if event.get("aggregateversion") != 2:
            fail(f"publication reconcile stream version mismatch for {event['subject']}")
        if event.get("commandkind") != "MUTATION" or event.get("entityscope") != "HOST":
            fail(f"publication reconcile metadata mismatch for {event['subject']}")
        expected_data = dict(original["data"])
        expected_data.update({"aggregateVersion": 1, "newAggregateVersion": 2})
        if event.get("data") != expected_data:
            fail(f"publication reconcile payload drifted for {event['subject']}")
        if str(event.get("nonce")) != "0":
            fail("publication reconcile must use the importer nonce sentinel")
        reconcile_ids.add(event["id"])
    if len(reconcile_ids) != 3:
        fail("publication reconcile event identifiers are not unique")
    for identifier in reconcile_ids:
        parsed = uuid.UUID(identifier)
        if parsed.version != 7 or parsed.variant != uuid.RFC_4122:
            fail(f"publication reconcile identifier is not RFC 4122 UUID v7: {identifier}")

    api_events = json.loads(API_CLOSURE_DELTA.read_text(encoding="utf-8"))
    if len(api_events) != 2 or {event["data"]["apiId"] for event in api_events} != {"LPS1110", "LPS1111"}:
        fail("P7 API closure must update exactly the Host query and command specs")
    retired = (
        "Provision", "RetryOperational", "CredentialRotation", "RetentionHold",
        "Decommission", "getOperationalStoreProfiles",
    )
    required = {
        "LPS1110": {"lightapi.net/host/getOperationalStoreBindings/0.1.0"},
        "LPS1111": {
            "lightapi.net/host/registerOperationalStoreBinding/0.2.0",
            "lightapi.net/host/updateOperationalStoreBinding/0.2.0",
            "lightapi.net/host/deactivateOperationalStoreBinding/0.2.0",
            "lightapi.net/host/unregisterOperationalStoreBinding/0.2.0",
        },
    }
    for event in api_events:
        data = event["data"]
        endpoints = {endpoint["endpoint"] for endpoint in data["endpoints"]}
        if event["type"] != "ApiVersionSpecUpdatedEvent" or event["aggregateversion"] != 2:
            fail("P7 API closure has the wrong event type or aggregate version")
        if not required[data["apiId"]].issubset(endpoints):
            fail(f"P7 API closure is missing registration endpoints for {data['apiId']}")
        if any(token in endpoint for token in retired for endpoint in endpoints):
            fail(f"P7 API closure retains a provisioning endpoint for {data['apiId']}")
        if str(event.get("nonce")) != "0":
            fail("P7 API closure must use the importer nonce sentinel")
    api_text = json.dumps(api_events)
    if "SECRET_REFERENCE" in api_text:
        fail("API closure advertises an unimplemented credential source")
    register_endpoint = next(endpoint for event in api_events
                             for endpoint in event["data"]["endpoints"]
                             if endpoint["endpointName"] == "registerOperationalStoreBinding")
    register_operation = register_endpoint["lightapiDocument"]["operations"][
        "registerOperationalStoreBinding"]
    if not register_operation["idempotency"]["safeToRetry"]:
        fail("registration API does not advertise idempotent retry support")

    print("operational-store registration event contract passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
