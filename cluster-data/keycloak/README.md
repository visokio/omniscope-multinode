# Keycloak — OIDC Authentication

Provides SSO for both editor and viewer clusters. Admin console: **http://keycloak.localhost:9900/admin**

```
Username: admin
Password: admin
```

## Folder structure

```
keycloak/
├── realm-export/
│   └── realm.json     Bootstraps Keycloak on first start (version controlled)
└── README.md          This file
```

> `data/` (the PostgreSQL database) lives in `cluster-test/keycloak/data/` at runtime — it is ephemeral and destroyed by `cluster-test/delete.sh`. It is not stored here in `cluster-data/`.

## What is pre-configured (from realm.json)

| What | Value |
|---|---|
| Realm | `visokio` |
| Editor client | `omniscope-editor` — secret: `omniscope-editor-secret-change-in-production` |
| Viewer client | `omniscope-viewer` — secret: `omniscope-viewer-secret-change-in-production` |
| Test editor user | `editor-user` / `editor123` — has `editor-role` |
| Test viewer user A | `viewer-user-a` / `viewer123` — has `viewer-role` |
| Test viewer user B | `viewer-user-b` / `viewer123` — has `viewer-role` |

`realm.json` is only imported once — on first start when the database is empty. After that, all changes should be made in the admin UI and exported back.

## OIDC is pre-configured — no setup needed

Both the editor and viewer clusters are already configured to use Keycloak via the committed `omniscope-server/` bootstrap files in `cluster-data/`. You do not need to manually set up OIDC. The issuer URI used by all nodes is:

```
http://keycloak.localhost:9900/realms/visokio/
```

This hostname works from the browser (RFC 6761 `.localhost` subdomain resolution) and from inside Docker (OpenResty DNS alias on the Docker network). See the README for a full explanation.

## How roles reach Omniscope

`realm.json` includes a protocol mapper that injects realm roles into every JWT token under the claim name `roles`. Omniscope reads this claim when matching users to permission groups.

```
User logs in → Keycloak issues JWT with "roles": ["editor-role"] → Omniscope matches group
```

## Updating the realm

1. Make changes in the admin console
2. Export: Realm Settings → Action → Partial Export (include clients and users)
3. Replace `realm-export/realm.json` and commit it

## Production checklist

- [ ] Change Keycloak admin password
- [ ] Change client secrets in `realm.json` and in each Omniscope cluster's config
- [ ] Enable SSL (`KC_HTTPS_*` settings)
- [ ] Set `sslRequired: "external"` in the realm
- [ ] Replace `keycloak.localhost` with your real public hostname
- [ ] Replace test users with real users or connect LDAP/AD
