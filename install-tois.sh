#!/usr/bin/env bash
# Scripted install of TOIS (Transpara Agentic Monitoring) on Kubernetes.
# Idempotent + order-independent with model-builder-install.
#
# Both TOIS and Model Builder share a single `claude-subscription-gateway`
# pod. This installer:
#   - REUSES an existing gateway if one is running anywhere on the
#     cluster (any namespace), regardless of who installed it.
#   - INSTALLS a fresh gateway + generates a shared api-key secret if
#     none exists.
#   - Prompts for a Claude subscription setup-token only when it
#     installed the gateway fresh (otherwise the login already lives
#     in the discovered gateway).
#
# Runtime settings (gateway URL, MCP URL, Transpara credentials,
# enricher, model) live in a JSON file on the PVC (/data/tois-settings.json)
# — editable via the Settings page after install. This script seeds
# that file on first deploy.
#
# Self-contained: run it next to a deploy/k8s directory (a clone of
# transpara/tois-install or transpara/operational-intelligence-service)
# and it uses those manifests; run it standalone and it fetches them
# from the public transpara/tois-install repo.
#
# Usage:
#   ./install-tois.sh                             # interactive install
#   ./install-tois.sh --rotate-transpara-password # force re-prompt for
#                                                 # tGraph credentials
#   ./install-tois.sh --skip-claude-login         # deploy gateway fresh
#                                                 # but skip the login flow
#                                                 # (do it later from the
#                                                 # gateway pod directly)
#
# Images pull anonymously from registry.transpara.com — no registry
# credentials needed.
set -euo pipefail

NS=model-builder
MANIFEST_TARBALL="https://github.com/transpara/tois-install/archive/refs/heads/main.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROTATE_PW=false
SKIP_LOGIN=false
for arg in "$@"; do
  case "$arg" in
    --rotate-transpara-password) ROTATE_PW=true ;;
    --skip-claude-login)         SKIP_LOGIN=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

say()  { echo; echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Wrap `kubectl rollout status` with a background ticker that prints
# pod state + the latest event every 10s. Without this, image pulls
# look like a hang for 30-90s at a time. Args: <deploy-name> [timeout].
wait_for_rollout_with_progress() {
  local deploy="$1"
  local timeout="${2:-300s}"
  local selector="app=${deploy}"
  local start=$(date +%s)
  # The whole function runs with errexit off — we kill our background
  # ticker (SIGTERM) and `wait` for it, both of which return non-zero
  # under normal termination and would blow up the outer `set -e`.
  set +e

  (
    while true; do
      sleep 10
      local elapsed=$(( $(date +%s) - start ))
      local pod_state
      pod_state=$($KUBECTL -n "$NS" get pod -l "$selector" \
        -o 'jsonpath={range .items[*]}{.status.phase}{" "}{range .status.containerStatuses[*]}{.name}={.state}{" "}{end}{"\n"}{end}' 2>/dev/null \
        | tr -d '\n' | head -c 300)
      local last_event
      last_event=$($KUBECTL -n "$NS" get events --sort-by=.lastTimestamp \
        --field-selector "involvedObject.kind=Pod" 2>/dev/null \
        | grep -E "${deploy}-|Pulling|Pulled|Created|Started" \
        | tail -1 | awk '{$1=""; print}' | head -c 220)
      printf "  [%3ds] %s\n" "$elapsed" "${pod_state:-…}"
      [ -n "$last_event" ] && printf "         %s\n" "$last_event"
    done
  ) &
  local ticker=$!

  $KUBECTL -n "$NS" rollout status "deploy/$deploy" --timeout="$timeout"
  local rc=$?
  kill "$ticker" 2>/dev/null
  wait "$ticker" 2>/dev/null
  set -e
  return "$rc"
}

# Manifests: prefer a deploy/k8s next to (or one level above) the script;
# otherwise fetch the public install repo tarball. No credentials needed.
REPO_ROOT=""
for cand in "$SCRIPT_DIR/.." "$SCRIPT_DIR"; do
  if [ -d "$cand/deploy/k8s" ]; then REPO_ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$REPO_ROOT" ]; then
  say "No local deploy/k8s next to the script; fetching manifests"
  TMP_SRC="$(mktemp -d)"
  trap 'rm -rf "$TMP_SRC"' EXIT
  curl -fsSL "$MANIFEST_TARBALL" | tar xz -C "$TMP_SRC" --strip-components=1
  [ -d "$TMP_SRC/deploy/k8s" ] || die "failed to fetch manifests from $MANIFEST_TARBALL"
  REPO_ROOT="$TMP_SRC"
fi

# ── kubectl / cluster access ─────────────────────────────────────────────
say "Checking cluster access"
KUBECTL=""
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif sudo -n true 2>/dev/null && sudo kubectl get nodes >/dev/null 2>&1; then
  KUBECTL="sudo kubectl"
elif command -v kubectl >/dev/null 2>&1 && sudo kubectl get nodes >/dev/null 2>&1; then
  KUBECTL="sudo kubectl"
fi
[ -n "$KUBECTL" ] || die "no working kubectl. Install k3s first (see model-builder-install --install-k3s), then re-run."

$KUBECTL wait --for=condition=Ready node --all --timeout=60s >/dev/null 2>&1 || true
echo "Cluster reachable: $($KUBECTL get nodes --no-headers | wc -l) node(s) Ready (using: $KUBECTL)"

# ── gateway discovery ────────────────────────────────────────────────────
#
# Look for a `claude-subscription-gateway` deployment anywhere on the
# cluster. If found we reuse it (whoever installed it — us, Model
# Builder, a future sibling app — the gateway is shared cluster-wide).
# If not found we install one ourselves alongside TOIS.
say "Looking for an existing claude-subscription-gateway"
GATEWAY_NS=$($KUBECTL get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="claude-subscription-gateway")]}{.metadata.namespace}{"\n"}{end}' | head -1)

FRESH_GATEWAY=false
if [ -n "$GATEWAY_NS" ]; then
  echo "Found claude-subscription-gateway in namespace: $GATEWAY_NS"
  GATEWAY_URL_IN_CLUSTER="http://claude-subscription-gateway.${GATEWAY_NS}.svc.cluster.local:8790/v1/messages"
  # gateway-secrets lives with the deployment.
  $KUBECTL -n "$GATEWAY_NS" get secret gateway-secrets >/dev/null 2>&1 \
    || die "gateway found in $GATEWAY_NS but secret 'gateway-secrets' is missing there. This is unusual — did the gateway install partially fail?"
  CSG_API_KEY=$($KUBECTL -n "$GATEWAY_NS" get secret gateway-secrets \
    -o jsonpath='{.data.CSG_API_KEY}' | base64 -d)
  [ -n "$CSG_API_KEY" ] || die "CSG_API_KEY empty in $GATEWAY_NS/gateway-secrets"
else
  echo "No existing gateway found — will install one alongside TOIS in namespace '$NS'"
  FRESH_GATEWAY=true
  GATEWAY_URL_IN_CLUSTER="http://claude-subscription-gateway.${NS}.svc.cluster.local:8790/v1/messages"
fi

# ── namespace + gateway-secrets (only when we're standing up a gateway) ──
if [ "$FRESH_GATEWAY" = true ]; then
  say "Preparing namespace + gateway credentials"
  $KUBECTL get namespace "$NS" >/dev/null 2>&1 || $KUBECTL create namespace "$NS"

  if $KUBECTL -n "$NS" get secret gateway-secrets >/dev/null 2>&1; then
    echo "gateway-secrets already exists in $NS; reusing"
  else
    $KUBECTL -n "$NS" create secret generic gateway-secrets \
      --from-literal=CSG_API_KEY="$(openssl rand -hex 32)" \
      --from-literal=CSG_ADMIN_PASSWORD="$(openssl rand -hex 12)"
    echo "gateway-secrets created (fresh CSG_API_KEY + admin password)"
  fi
  CSG_API_KEY=$($KUBECTL -n "$NS" get secret gateway-secrets \
    -o jsonpath='{.data.CSG_API_KEY}' | base64 -d)
fi

# ── deploy ───────────────────────────────────────────────────────────────
#
# The kustomization always includes the gateway manifests. When the
# gateway already exists (found via discovery above), `kubectl apply`
# is a no-op on the identical objects. When we're installing fresh,
# it creates them.
say "Applying manifests"
$KUBECTL apply -k "$REPO_ROOT/deploy/k8s/"

if [ "$FRESH_GATEWAY" = true ]; then
  say "Waiting for gateway rollout (first image pull can take a few minutes)"
  wait_for_rollout_with_progress claude-subscription-gateway 600s
fi

say "Waiting for TOIS rollouts (first image pulls can take a few minutes)"
wait_for_rollout_with_progress tois    600s
wait_for_rollout_with_progress tois-ui 300s

# ── Claude subscription login ────────────────────────────────────────────
#
# Probe on EVERY run, not just fresh installs. A gateway can exist but
# not be logged in — e.g. a previous install created it and died before
# reaching setup-token, or the token was revoked. In those cases the
# rerun must offer to log in, otherwise wire probes silently fail.
#
# Same pattern as model-builder-install's probe_login().
say "Checking Claude subscription login"
probe_login() {
  $KUBECTL -n "$NS" exec deploy/claude-subscription-gateway -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
    -X POST http://localhost:8790/v1/messages \
    -H "x-api-key: $CSG_API_KEY" -H 'content-type: application/json' \
    -d '{"model":"sonnet","max_tokens":8,"messages":[{"role":"user","content":"Reply with exactly: ok"}]}' \
    2>/dev/null || echo 000
}
CODE=$(probe_login)
if [ "$CODE" = "200" ]; then
  echo "Subscription login present and working (probe: 200)"
elif [ "$SKIP_LOGIN" = true ] || [ ! -t 0 ]; then
  warn "gateway not logged in (probe returned $CODE); skipping interactive login. Run 'kubectl -n $NS exec -it deploy/claude-subscription-gateway -- claude setup-token' when you have a TTY."
else
  echo "The gateway has no working Claude login yet (probe returned $CODE)."
  read -rp "Run 'claude setup-token' in the gateway pod now? [y/N] " yn
  if [ "${yn,,}" = "y" ]; then
    $KUBECTL -n "$NS" exec -it deploy/claude-subscription-gateway -- claude setup-token || true
    echo
    echo "The CLI printed a long-lived token (sk-ant-oat01-...) but does NOT store it."
    echo "Paste it below; it is saved into the gateway-secrets secret, which the"
    echo "gateway injects into every claude call (survives restarts and updates)."
    # The token is ~108 chars and often wraps across two terminal lines
    # when printed; a scrollback copy can carry a line break and silently
    # truncate at the hidden prompt (seen live: half-token -> 401 every call).
    while true; do
      read -rsp "Token (hidden; Enter to skip): " OAUTH_TOKEN; echo
      [ -z "$OAUTH_TOKEN" ] && break
      OAUTH_TOKEN="$(printf %s "$OAUTH_TOKEN" | tr -d '[:space:]')"
      case "$OAUTH_TOKEN" in
        sk-ant-oat01-*)
          if [ "${#OAUTH_TOKEN}" -ge 80 ]; then break; fi
          echo "That looks truncated (${#OAUTH_TOKEN} chars, expected ~108). If the token"
          echo "wrapped across two lines on screen, the clipboard split it: paste it into"
          echo "a text editor, join to one line, copy again, then retry."
          ;;
        *)
          echo "That does not look like a setup-token value (should start with sk-ant-oat01-). Try again."
          ;;
      esac
    done
    if [ -n "$OAUTH_TOKEN" ]; then
      $KUBECTL -n "$NS" patch secret gateway-secrets --type merge \
        -p "{\"stringData\":{\"CSG_CLAUDE_OAUTH_TOKEN\":\"$OAUTH_TOKEN\"}}"
      # Belt and suspenders: ensure the deployment reads the secret even
      # if the applied manifest predates the token wiring.
      $KUBECTL -n "$NS" set env deploy/claude-subscription-gateway \
        --from=secret/gateway-secrets --keys=CSG_CLAUDE_OAUTH_TOKEN >/dev/null || true
      $KUBECTL -n "$NS" rollout restart deploy/claude-subscription-gateway
      $KUBECTL -n "$NS" rollout status deploy/claude-subscription-gateway --timeout=180s
    fi
    CODE=$(probe_login)
    if [ "$CODE" = "200" ]; then
      echo "Login verified end to end"
    else
      warn "probe still returns $CODE after login attempt; check gateway logs"
    fi
  else
    warn "skipped Claude login; the wire probe below will fail until you run 'claude setup-token' in the pod"
  fi
fi

# ── seed TOIS runtime settings ───────────────────────────────────────────
say "Seeding TOIS runtime settings"

CURRENT=$($KUBECTL -n "$NS" exec deploy/tois -- python -c "
import urllib.request
r = urllib.request.urlopen('http://localhost:8788/api/admin/settings', timeout=10)
print(r.read().decode())
")

PW_SET=$(echo "$CURRENT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('transpara_password') else 'no')")

TP_USER=""
TP_PASS=""
if [ "$PW_SET" = "yes" ] && [ "$ROTATE_PW" != true ]; then
  echo "Transpara password already set; skipping prompt (pass --rotate-transpara-password to overwrite)"
else
  if [ ! -t 0 ]; then
    warn "no interactive terminal and no stored password — skipping credentials seed. Set them via the Settings page."
  else
    echo "TOIS writes run briefs + per-finding comments to tGraph as a Transpara user."
    echo "Enter that user's credentials (typically 'tai')."
    read -rp "Transpara username [tai]: " TP_USER
    TP_USER="${TP_USER:-tai}"
    read -rsp "Transpara password: " TP_PASS; echo
    [ -n "$TP_PASS" ] || die "password is required"
  fi
fi

# Build the seed payload. Gateway URL points at the discovered
# service DNS (which may be cross-namespace); Transpara base URL
# defaults to borgdev but is editable via Settings later.
PAYLOAD=$(TP_USER="$TP_USER" TP_PASS="$TP_PASS" CSG_API_KEY="$CSG_API_KEY" GATEWAY_URL="$GATEWAY_URL_IN_CLUSTER" python3 <<'PY'
import json, os
p = {
    "transpara_base_url": "https://borgdev.transpara.io",
    "gateway_url": os.environ["GATEWAY_URL"],
    "gateway_api_key": os.environ["CSG_API_KEY"],
    "mcp_url": "http://transpara-mcp.transpara.svc.cluster.local/mcp",
    "enricher": "gateway",
    "narrative_model": "claude-sonnet-4-6",
}
if os.environ.get("TP_PASS"):
    p["transpara_username"] = os.environ["TP_USER"]
    p["transpara_password"] = os.environ["TP_PASS"]
print(json.dumps(p))
PY
)

$KUBECTL -n "$NS" exec -i deploy/tois -- python -c "
import sys, urllib.request
body = sys.stdin.read().encode()
req = urllib.request.Request(
    'http://localhost:8788/api/admin/settings',
    data=body, method='PUT',
    headers={'Content-Type': 'application/json'},
)
print(urllib.request.urlopen(req, timeout=15).read().decode())
" <<<"$PAYLOAD" >/dev/null && echo "settings seeded"

# ── wire checks ──────────────────────────────────────────────────────────
say "End-to-end wire checks"
GATEWAY_PROBE=$($KUBECTL -n "$NS" exec deploy/tois -- python -c "
import urllib.request
r = urllib.request.urlopen(urllib.request.Request(
    'http://localhost:8788/api/admin/settings/test-gateway',
    data=b'{}', method='POST', headers={'Content-Type':'application/json'}), timeout=30)
print(r.read().decode())
")
echo "  gateway: $GATEWAY_PROBE"
echo "$GATEWAY_PROBE" | grep -q '"ok":[ ]*true' \
  || warn "gateway probe failed; check the gateway pod + subscription login"

TP_PROBE=$($KUBECTL -n "$NS" exec deploy/tois -- python -c "
import urllib.request
r = urllib.request.urlopen(urllib.request.Request(
    'http://localhost:8788/api/admin/settings/test-transpara',
    data=b'{}', method='POST', headers={'Content-Type':'application/json'}), timeout=30)
print(r.read().decode())
")
echo "  transpara: $TP_PROBE"
echo "$TP_PROBE" | grep -q '"ok":[ ]*true' \
  || warn "transpara probe failed; re-run with --rotate-transpara-password if creds are wrong, or set them via the Settings page"

# ── summary ──────────────────────────────────────────────────────────────
NODE_IP=$($KUBECTL get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
say "Done"
echo "UI:            http://$NODE_IP:30788"
echo "Gateway:       $GATEWAY_URL_IN_CLUSTER  ($([ "$FRESH_GATEWAY" = true ] && echo 'installed by TOIS' || echo "reused from namespace $GATEWAY_NS"))"
echo "Rotate creds:  $0 --rotate-transpara-password"
echo "Rollout after new CI image: $KUBECTL -n $NS rollout restart deploy/tois deploy/tois-ui"
