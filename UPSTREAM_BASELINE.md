# Upstream baseline

The initial scaffold was exported from the committed tree of:

```text
repository: lightapi/portal-config-dev
commit: d597470ef0ae6ddf883d2fc88622cf1eb5431cf2
commit date: 2026-08-30
```

The export intentionally excluded the source checkout's working-tree changes.

For daily maintenance, first allow the public daily release and dev deployment
to finish and pass their gates. Then compare the new committed baseline with
this repository. Bring forward baseline service, schema, event-delta, and
script changes while retaining these Bootstrap-owned boundaries:

- `docker-compose.bootstrap.yml`
- `.env.bootstrap.example`
- `portal-bff-sso/`
- `docs/bootstrap-data-lifecycle.md`
- Bootstrap build, TLS, restart, and validation scripts

Never sync runtime data, generated UI assets, private TLS material, env files,
or uncommitted changes. Record the new upstream commit here and run
`./scripts/validate-bootstrap.sh` plus the Bootstrap smoke tests before making
the refreshed VM available.
