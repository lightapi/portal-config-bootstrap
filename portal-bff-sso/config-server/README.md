# Config Server snapshot for portal-bff-sso

`portal-bff-sso/config/startup.yml` selects a dedicated snapshot by customer
host, service ID, and environment tag. Before starting the service, create that
snapshot in Light Portal/Config Server.

Use the existing Portal BFF snapshot as the base so all Portal routes, proxy
destinations, `security.yml`, `client.yml`, CORS, static content, and virtual
host configuration are retained. Then make these scoped changes:

1. Replace `stateless-auth` in the customer BFF handler chain with
   `msal-exchange`. Keep `cors` before it.
2. Merge `handler-msal-fragment.yml` into the full `handler.yml`; do not publish
   the fragment as the complete file.
3. Add `msal-exchange.yml` and `security-msal.yml`.
4. Merge `client-token-exchange-fragment.yml` under `oauth.token` in the full
   `client.yml`.
5. Set the virtual host to `dev.yourcompany.com` (or `CUSTOMER_PORTAL_HOST`) and
   retain the Portal API and SPA routes from the source snapshot.
6. Keep normal `security.yml`: it verifies the Light OAuth token returned by
   the exchange. `security-msal.yml` verifies the incoming Entra token.
7. Publish the snapshot for the exact `(host, serviceId, envTag)` tuple in
   `.env.bootstrap` and test it before promoting it to POC.

The committed YAML files are reviewable source material. Runtime secrets stay
in `.env.bootstrap` or the enterprise secret manager and must not be placed in
Config Server events or committed to Git.
