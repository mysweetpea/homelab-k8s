# Authentik SSO Reconfig — UI-First Runbook (Session 35)

> **Target:** Authentik **2026.5.6** (latest stable; 2026.8.0 is RC — do NOT use).
> **Admin URL:** https://auth.mysweetpea.cc  (user `akadmin`)
> **Workflow:** Create objects in the UI → export each as a blueprint (`{ }` icon)
> → sanitize → wire into `values.yaml`.

---

## 0. Pre-flight (verify current state)

```bash
# Confirm server + worker on 2026.5.6
kubectl -n dmz get pod -l app.kubernetes.io/name=authentik \
  -o jsonpath='{.items[*].spec.containers[0].image}'

# Confirm groups exist (recreated Session 31)
# UI: Directory → Groups → expect: seedling, sweetpea
```

**Groups (already created):**
| Group | UUID |
|-------|------|
| `seedling` | `e78a189b-6b60-43e4-8fb1-8fd1672d9eaf` |
| `sweetpea` | `038c4ae4-6188-4928-9555-cd29aa6d43e9` |

---

## 1. Create the 5 Applications + Providers

> **Critical:** Application **slug MUST exactly match the provider name** — the OIDC
> issuer path is `/application/o/<slug>/`. If they differ, OIDC discovery breaks.

### 1.1 Vaultwarden (OIDC)
**Provider** (Applications → Providers → Create → OAuth2/OIDC Provider):
- **Name:** `vaultwarden`
- **Client Type:** Confidential
- **Client ID:** `<from credentials note>`
- **Client Secret:** `<from credentials note>`
- **Redirect URIs:** `https://vault.mysweetpea.cc/identity/connect/oidc-signin`
- **Signing Key:** (create a new RSA key, e.g. `vaultwarden-signing-key`)
- **Access Code Validity:** 5 minutes (or longer — must be > 5 min for Vaultwarden)
- **Access Token Validity:** 5 minutes
- **Scopes:** `email`, `profile`, `offline_access`
- **Sub Mode:** Hashed User ID
- **Include claims in ID Token:** ✅ (checked)
- **PKCE:** ✅ **Enabled** (must match Vaultwarden `SSO_PKCE=true`)

**Application** (Applications → Applications → Create):
- **Name:** `Vaultwarden`
- **Slug:** `vaultwarden`  ← MUST match provider name
- **Provider:** `vaultwarden`
- **Launch URL:** `https://vault.mysweetpea.cc`

### 1.2 AFFiNE (OIDC)
**Provider:**
- **Name:** `affine`
- **Client Type:** Confidential
- **Client ID:** `<from credentials note>`
- **Client Secret:** `<from credentials note>`
- **Redirect URIs:** `https://notes.mysweetpea.cc/oauth/callback`
- **Signing Key:** new RSA key `affine-signing-key`
- **Scopes:** `openid`, `email`, `profile`
- **Sub Mode:** Hashed User ID
- **Claims mapping (Advanced → Protocol):**
  - `sub` → `preferred_username`
  - `name` → `name`
  - `email` → `email`

**Application:**
- **Name:** `AFFiNE`
- **Slug:** `affine`
- **Provider:** `affine`
- **Launch URL:** `https://notes.mysweetpea.cc`

### 1.3 Matrix Synapse (OIDC)
**Provider:**
- **Name:** `matrix-synapse`
- **Client Type:** Confidential
- **Client ID:** `<from credentials note>`
- **Client Secret:** `<from credentials note>`
- **Redirect URIs:** `https://matrix.mysweetpea.cc/_synapse/client/oidc/callback`
- **Signing Key:** new RSA key `matrix-signing-key`
- **Scopes:** `openid`, `email`, `profile`
- **Sub Mode:** Hashed User ID

**Application:**
- **Name:** `Matrix Synapse`
- **Slug:** `matrix-synapse`
- **Provider:** `matrix-synapse`
- **Launch URL:** `https://matrix.mysweetpea.cc`

### 1.4 Jellyfin (LDAP)
**Provider** (Applications → Providers → Create → LDAP Provider):
- **Name:** `jellyfin`
- **Server URI:** `ldap://authentik-ldap-outpost.dmz.svc.cluster.local:3389`
- **Base DN:** `dc=mysweetpea,dc=cc`
- **Bind DN:** `cn=ldap-service-account,ou=users,dc=mysweetpea,dc=cc`
- **Bind Password:** `<from credentials note>`
- **Search Group:** *(leave empty — no `all_users` group)*
- **Search Mode:** `Cached querying`
- **Bind Mode:** `Cached binding`
- **Certificate:** (self-signed CA from `authentik-ca-cert` ConfigMap)

**Application:**
- **Name:** `Jellyfin`
- **Slug:** `jellyfin`
- **Provider:** `jellyfin`
- **Launch URL:** `https://media.mysweetpea.cc`

### 1.5 KoalaSync (Proxy)
**Provider** (Applications → Providers → Create → Proxy Provider):
- **Name:** `koalasync`
- **Authentication Flow:** `default-authentication-flow`
- **Authorization Flow:** `default-provider-authorization-explicit-consent`
- **Mode:** `Forward auth (single application)`
- **External Host:** `https://sync.mysweetpea.cc`
- **Cookie Domain:** `mysweetpea.cc`
- **External Path:** `/`

**Application:**
- **Name:** `KoalaSync`
- **Slug:** `koalasync`
- **Provider:** `koalasync`
- **Launch URL:** `https://sync.mysweetpea.cc`

---

## 2. Add Bindings (per application → Bindings tab)

| Application | Groups bound | Policy Engine Mode |
|-------------|--------------|--------------------|
| Vaultwarden | seedling + sweetpea | ANY |
| AFFiNE | seedling + sweetpea | ANY |
| Matrix Synapse | seedling + sweetpea | ANY |
| **Jellyfin** | **sweetpea only** | ANY |
| KoalaSync | seedling + sweetpea | ANY |

> In each app's **Bindings** tab: click **Create binding** → select the group(s)
> → Policy Engine Mode = **ANY** (a user in *any* bound group is allowed).

---

## 3. Create the Outposts

**LDAP Outpost** (Applications → Outposts → Create):
- **Name:** `authentik-ldap-outpost`
- **Type:** LDAP
- **Token:** `<from credentials note>`
- **Applications:** Jellyfin
- **Protocol settings:** Base DN `dc=mysweetpea,dc=cc`, bind DN `cn=ldap-service-account,ou=users,dc=mysweetpea,dc=cc`

**Proxy Outpost** (Applications → Outposts → Create):
- **Name:** `authentik-proxy-outpost`
- **Type:** Proxy
- **Token:** `<from credentials note>`
- **Applications:** KoalaSync

> The outpost **Deployments already exist in the cluster** (pinned to k3s-master,
> image `2026.5.6`, tokens from the sealed secrets). Creating the outpost in the
> UI with the **same token** makes the running pods authenticate to the server.
> Do **not** deploy a new outpost from the UI — the cluster Deployment is the
> source of truth.

---

## 4. Create the 3 NEW Applications (open-webui, nextcloud, immich)

> IngressRoutes already exist in git (`apps/private/ingress-routes/ingress-routes.yaml`).
> Cloudflare DNS records (CNAME → tunnel) must exist for chat/cloud/photos.

### 4.1 open-webui (OIDC) → chat.mysweetpea.cc
**Provider:**
- **Name:** `open-webui`
- **Client Type:** Confidential
- **Redirect URIs:** `https://chat.mysweetpea.cc/oauth/oidc/callback`
- **Signing Key:** new RSA key `open-webui-signing-key`
- **Scopes:** `openid`, `email`, `profile`
- **Sub Mode:** Hashed User ID

**Application:**
- **Name:** `Open WebUI`
- **Slug:** `open-webui`
- **Provider:** `open-webui`
- **Launch URL:** `https://chat.mysweetpea.cc`

**Open WebUI env vars** (in `apps/private/open-webui/values.yaml` — use these, NOT `OAUTH_OIDC_*`):
```yaml
OPENID_PROVIDER_URL: https://auth.mysweetpea.cc/application/o/open-webui/.well-known/openid-configuration
OAUTH_CLIENT_ID: <generated client id>
OAUTH_CLIENT_SECRET: <generated client secret>
OPENID_REDIRECT_URI: https://chat.mysweetpea.cc/oauth/oidc/callback
OAUTH_SCOPES: "openid email profile"
ENABLE_OAUTH_SIGNUP: "true"
```

### 4.2 nextcloud (OIDC) → cloud.mysweetpea.cc
**Provider:**
- **Name:** `nextcloud`
- **Client Type:** Confidential
- **Redirect URIs:** `https://cloud.mysweetpea.cc/apps/user_oidc/callback`
- **Signing Key:** new RSA key `nextcloud-signing-key`
- **Scopes:** `openid`, `email`, `profile`
- **Sub Mode:** Hashed User ID
- **Auth method:** `client_secret_basic` (or `client_secret_post` if discovery lacks `token_endpoint_auth_methods_supported`)

**Application:**
- **Name:** `Nextcloud`
- **Slug:** `nextcloud`
- **Provider:** `nextcloud`
- **Launch URL:** `https://cloud.mysweetpea.cc`

> **Prereq:** Install the **user_oidc** app in Nextcloud (Apps → user_oidc), then
> configure the provider URL + client ID/secret in Nextcloud admin.

### 4.3 immich (OIDC) → photos.mysweetpea.cc
**Provider:**
- **Name:** `immich`
- **Client Type:** Confidential
- **Redirect URIs:**
  - `https://photos.mysweetpea.cc/auth/login`
  - `https://photos.mysweetpea.cc/user-settings`
  - `app.immich:///oauth-callback`
- **Signing Key:** new RSA key `immich-signing-key`
- **Scopes:** `openid`, `email`, `profile`
- **Sub Mode:** Hashed User ID

**Application:**
- **Name:** `Immich`
- **Slug:** `immich`
- **Provider:** `immich`
- **Launch URL:** `https://photos.mysweetpea.cc`

> **Prereq:** Configure OAuth in Immich admin UI (Administration → Settings →
> OAuth): issuer URL, client ID/secret, scopes `openid email profile`, **Auto
> Register = true**. Not env vars.

---

## 5. Export → Sanitize → Wire into Git

For **each** object (provider, application, binding, outpost), open its detail
page and click the **`{ }`** icon (top-right) → **Export as Blueprint** → save the
YAML into `apps/dmz/authentik/blueprints/`.

Then on k3s-master (or here, if you copy the files in):

```bash
cd /home/user/homelab-k8s/apps/dmz/authentik/blueprints

# 1. Sanitize every exported blueprint (rewrites secrets to !Env tags)
python3 sanitize-blueprints.py *.yaml

# 2. Generate the additionalObjects ConfigMap block
python3 build-configmap.py
#   -> paste the printed `additionalObjects:` block into values.yaml

# 3. Create/update the env Secret with the AUTHENTIK_BP_* vars the sanitizer reported
kubectl -n dmz create secret generic authentik-blueprint-env \
  --from-literal=AUTHENTIK_BP_VAULTWARDEN_CLIENT_SECRET='<value>' \
  --from-literal=AUTHENTIK_BP_AFFINE_CLIENT_SECRET='<value>' \
  ... # (all vars from step 1 output)

# 4. Uncomment the two blocks in values.yaml:
#    blueprints.configMaps: [authentik-blueprints]
#    global.envFrom: [{secretRef: {name: authentik-blueprint-env}}]

# 5. Commit + push, then sync
git add -A && git commit -m "Session 35: wire Authentik SSO blueprints" && git push
argocd login 192.168.20.220 --username admin --password mysweetpea --insecure
argocd app sync authentik
```

> ⚠️ **Do NOT uncomment the blueprint blocks until the ConfigMap + Secret exist** —
> otherwise the server/worker pods fail to mount and SSO goes down.

---

## 6. Verify

```bash
# Server + worker healthy
kubectl -n dmz get pod -l app.kubernetes.io/name=authentik

# OIDC discovery responds for each app
curl -s https://auth.mysweetpea.cc/application/o/vaultwarden/.well-known/openid-configuration | head -c 200
curl -s https://auth.mysweetpea.cc/application/o/affine/.well-known/openid-configuration | head -c 200
curl -s https://auth.mysweetpea.cc/application/o/matrix-synapse/.well-known/openid-configuration | head -c 200

# KoalaSync forward-auth: unauthenticated -> 302 to Authentik login
curl -sI https://sync.mysweetpea.cc | grep -i location
```
