# TOIS — Kubernetes Installer

Installs **Transpara Agentic Monitoring** (**TOIS**) to a Kubernetes cluster
that already has **Model Builder** deployed. TOIS shares Model Builder's
namespace and reuses its `claude-subscription-gateway`, so you only pay
one Claude subscription and there is nothing new to log into.

At the end you will have:

- **TOIS** running with its UI on `http://<server-ip>:30788`
- Agent runs writing findings back to your tGraph as run briefs + per-finding
  comments (authored by the Transpara user you supply during install)
- A verified end-to-end wire check: the LLM gateway is reachable and the
  tGraph credentials work

```
Browser ──▶ TOIS UI (:30788 NodePort) ──▶ TOIS API (:8788 ClusterIP)
                                                │
                     ┌──────────────────────────┼──────────────────────────┐
                     ▼                          ▼                          ▼
        transpara-mcp (transpara ns)    claude-subscription-       tGraph API
        cross-namespace read layer       gateway (same ns)         (borgdev.transpara.io)
                                         reuses Model Builder's    run briefs + annotations
                                         subscription
```

This repository contains the installer script and the deployment manifests
(`deploy/k8s/`). It is public so nothing here needs credentials to download;
the application images pull anonymously from `registry.transpara.com`, so
no registry credentials are needed either.

---

## Prerequisites

**Model Builder must already be installed on the same cluster.** TOIS depends
on the `model-builder` namespace, the `gateway-secrets` secret (specifically
its `CSG_API_KEY`), and the running `claude-subscription-gateway` deployment
that Model Builder provisions. If you don't have Model Builder yet, install
it first:

> https://github.com/transpara/model-builder-install

**You will also need:**

- Your **Transpara username + password** — the account TOIS uses to
  authenticate against tGraph when posting run briefs and per-finding
  comments. Typically an `tai` service account created in your Transpara
  platform's Keycloak.
- **SSH access with sudo** on the target server (only needed if kubectl on
  the box requires it, e.g. on a fresh k3s install).

---

## Quick start

In an SSH session on the server — one line:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/transpara/tois-install/main/install-tois.sh)
```

> Use the `bash <(curl ...)` form exactly as written. The lookalike
> `curl ... | bash` does NOT work: piping takes over stdin, which breaks
> the script's interactive prompts.

Prefer to read it first, or keep a copy? Download-then-run works the same:

```bash
curl -fsSL https://raw.githubusercontent.com/transpara/tois-install/main/install-tois.sh \
  -o install-tois.sh
chmod +x install-tois.sh
./install-tois.sh
```

Cloning this repository and running `./install-tois.sh` from it also works;
the standalone script fetches the manifests itself.

**What happens next, in order:**

1. The script verifies the cluster is reachable and Model Builder's
   prerequisites are present (the `model-builder` namespace, the
   `gateway-secrets` secret, the `claude-subscription-gateway` deployment).
   Fails fast with a clear pointer if any are missing.
2. It deploys TOIS and the UI and waits for both pods to become Ready.
3. It seeds runtime settings by PUT-ing them to `/api/admin/settings`
   inside the pod: the k8s-canonical URLs (gateway, MCP, tGraph base)
   are hard-coded, and it prompts you once for a Transpara username +
   password. The store's `/data/tois-settings.json` on the PVC ends
   up owning all of that. Existing passwords are never overwritten on
   a re-run — pass `--rotate-transpara-password` to force.
4. It runs **end-to-end wire probes** via TOIS's own admin API:
   - `test-gateway` — sends a tiny prompt through the whole chain
     (TOIS → gateway → claude CLI → subscription) and reports the round-trip.
   - `test-transpara` — logs into tGraph with the credentials you supplied
     and fetches the auth'd user's comments. Prints "Logged in as X · N
     comments visible" on success.
5. Prints the UI address (`http://<server-ip>:30788`).

The script is idempotent: safe to re-run after fixing anything that failed.

---

## What lands on the cluster

Everything goes into the `model-builder` namespace (shared with Model
Builder itself):

| Object | Purpose |
|---|---|
| `Deployment tois` (1 replica, Recreate) | FastAPI + agent runner |
| `PVC tois-data` (2 Gi, zfs SC) | SQLite + `tois-settings.json` |
| `ConfigMap tois-config` | Ops config — scopes, per-agent overrides, business weights |
| `Service tois` (ClusterIP :8788) | in-cluster only |
| `Deployment tois-ui` (1 replica) | nginx serving the SPA + proxying `/api/` |
| `Service tois-ui` (NodePort :30788) | operator-facing entry point |

Runtime-tunable settings (gateway URL + API key, MCP URL, Transpara
credentials, enricher, model) live in `/data/tois-settings.json` on
the PVC — the installer seeds it, the Settings page edits it. No
Kubernetes Secret and no env vars for those.

TOIS reads MCP cross-namespace at
`http://transpara-mcp.transpara.svc.cluster.local/mcp` (unchanged from
whatever your Transpara platform install exposes) and writes tGraph
comments at `https://borgdev.transpara.io/tgraph`.

Both pods pass the cluster's Kyverno pod-security baseline: run non-root,
drop all capabilities, `seccompProfile: RuntimeDefault`, no host anything.

---

## Rollouts

New image versions land in Harbor via TOIS's CI on every merge to `main`.
To pick them up on the cluster:

```bash
kubectl -n model-builder rollout restart deploy/tois deploy/tois-ui
```

To roll back to an earlier immutable tag, edit `deploy/k8s/tois.yaml`
(and/or `tois-ui.yaml`) to reference the SHA tag instead of `latest`, then
`kubectl apply -k deploy/k8s/`.

---

## Rotate the Transpara password

Two ways:

**From the Settings page:** open the UI, Settings → Transpara →
Password → "Set new value…" → paste → Save. Takes effect immediately;
no pod restart.

**From the installer script:** if you've lost UI access,

```bash
./install-tois.sh --rotate-transpara-password
```

Re-prompts and PUTs the new password to `/api/admin/settings`. No pod
restart needed either.

---

## Troubleshooting

**"namespace 'model-builder' does not exist" / "secret gateway-secrets missing"**
You haven't installed Model Builder yet. Do that first:
https://github.com/transpara/model-builder-install

**"gateway probe failed" during install**
The TOIS pod is running but cannot reach the LLM. Usually means Model
Builder's Claude subscription isn't logged in. From your workstation:
```bash
kubectl -n model-builder port-forward deploy/claude-subscription-gateway 8790:8790
# then in another terminal:
kubectl -n model-builder exec deploy/claude-subscription-gateway -- claude setup-token
```
Follow model-builder-install's login flow.

**"transpara probe failed" during install**
TOIS logged in but got a 401 or the request failed. Most likely wrong
password. Re-run with `--rotate-secrets`. If the credentials are right
and it still fails, check the URL TOIS is hitting is reachable from the
cluster (`https://borgdev.transpara.io/tgraph` by default; edit
`deploy/k8s/tois.yaml` to change).

**Pods stuck in `ImagePullBackOff`**
Registry auth issue. TOIS's images are pushed to
`registry.transpara.com/transpara/tois*` and are meant to be pulled
anonymously. Check the pod's events:
```bash
kubectl -n model-builder describe pod -l app=tois | tail -30
```

---

## Manual install (no script)

If you want to see exactly what happens or prefer to apply manifests by
hand:

```bash
# 1. Prereq check (should exist from Model Builder install)
kubectl -n model-builder get secret gateway-secrets
kubectl -n model-builder get deploy claude-subscription-gateway

# 2. Apply manifests
kubectl apply -k deploy/k8s/

# 3. Watch
kubectl -n model-builder rollout status deploy/tois
kubectl -n model-builder rollout status deploy/tois-ui

# 4. Open the Settings page (http://<any-node-ip>:30788) and fill in
#    Transpara URL + username + password, gateway URL, MCP URL. Save.
```

UI at `http://<any-node-ip>:30788`.
