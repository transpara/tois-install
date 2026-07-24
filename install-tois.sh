#!/usr/bin/env bash
# Scripted install of TOIS (Transpara Agentic Monitoring) on Kubernetes.
# Idempotent: safe to re-run.
#
# TOIS shares the `model-builder` namespace and reuses the existing
# claude-subscription-gateway (already deployed there by
# transpara/model-builder-install). Model Builder MUST be installed on
# this cluster before running this script — the gateway + its API key
# secret come from that install.
#
# Runtime settings (gateway URL, MCP URL, Transpara credentials,
# enricher choice, narrative model) live in a JSON file on the PVC
# (`/data/tois-settings.json`) — editable via the Settings page after
# install. This script seeds that file on first deploy.
#
# Self-contained: run it next to a deploy/k8s directory (a clone of
# transpara/tois-install or transpara/operational-intelligence-service)
# and it uses those manifests; run it standalone and it fetches them
# from the public transpara/tois-install repo.
#
# Usage:
#   ./install-tois.sh                             # interactive install
#   ./install-tois.sh --rotate-transpara-password # force re-prompt
#
# Images pull anonymously from registry.transpara.com — no registry
# credentials needed.
set -euo pipefail

NS=model-builder
MANIFEST_TARBALL="https://github.com/transpara/tois-install/archive/refs/heads/main.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROTATE_PW=false
for arg in "$@"; do
  case "$arg" in
    --rotate-transpara-password) ROTATE_PW=true ;;
    *) echo "Unknown flag: $arg (supported: --rotate-transpara-password)" >&2; exit 1 ;;
  esac
done

say()  { echo; echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

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
[ -n "$KUBECTL" ] || die "no working kubectl. Install Model Builder first (its installer installs k3s), then re-run."

$KUBECTL wait --for=condition=Ready node --all --timeout=60s >/dev/null 2>&1 || true
echo "Cluster reachable: $($KUBECTL get nodes --no-headers | wc -l) node(s) Ready (using: $KUBECTL)"

# ── prerequisite: model-builder namespace + gateway-secrets ──────────────
say "Checking prerequisites (Model Builder must be installed first)"
$KUBECTL get namespace "$NS" >/dev/null 2>&1 \
  || die "namespace '$NS' does not exist. Install Model Builder first: https://github.com/transpara/model-builder-install"

$KUBECTL -n "$NS" get secret gateway-secrets >/dev/null 2>&1 \
  || die "secret '$NS/gateway-secrets' missing. Install Model Builder first: https://github.com/transpara/model-builder-install"
echo "gateway-secrets present (TOIS will reuse the CSG_API_KEY that Model Builder created)"

$KUBECTL -n "$NS" get deploy claude-subscription-gateway >/dev/null 2>&1 \
  || die "deployment '$NS/claude-subscription-gateway' missing. Install Model Builder first."
echo "claude-subscription-gateway deployment present"

CSG_API_KEY=$($KUBECTL -n "$NS" get secret gateway-secrets \
  -o jsonpath='{.data.CSG_API_KEY}' | base64 -d)
[ -n "$CSG_API_KEY" ] || die "CSG_API_KEY is empty in gateway-secrets"

# ── deploy ───────────────────────────────────────────────────────────────
say "Applying manifests"
$KUBECTL apply -k "$REPO_ROOT/deploy/k8s/"

say "Waiting for rollouts (first image pulls can take a few minutes)"
$KUBECTL -n "$NS" rollout status deploy/tois --timeout=300s
$KUBECTL -n "$NS" rollout status deploy/tois-ui --timeout=180s

# ── seed runtime settings ────────────────────────────────────────────────
#
# On first boot the store's /data/tois-settings.json doesn't exist,
# so TOIS starts with empty defaults. Seed it via the Settings API so
# the operator has a working system after this script finishes.
say "Seeding runtime settings"

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

# Build the seed payload — always include the k8s-canonical URLs +
# gateway API key (safe: same on-cluster values every run), and add
# username/password only when we actually collected them.
PAYLOAD=$(TP_USER="$TP_USER" TP_PASS="$TP_PASS" CSG_API_KEY="$CSG_API_KEY" python3 <<'PY'
import json, os
p = {
    "transpara_base_url": "https://borgdev.transpara.io",
    "gateway_url": "http://claude-subscription-gateway:8790/v1/messages",
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
  || warn "transpara probe failed; re-run with --rotate-transpara-password if creds are wrong"

# ── summary ──────────────────────────────────────────────────────────────
NODE_IP=$($KUBECTL get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
say "Done"
echo "UI:            http://$NODE_IP:30788"
echo "Rotate creds:  $0 --rotate-transpara-password"
echo "Rollout after new CI image: $KUBECTL -n $NS rollout restart deploy/tois deploy/tois-ui"
