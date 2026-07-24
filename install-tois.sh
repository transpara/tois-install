#!/usr/bin/env bash
# Scripted install of TOIS (Transpara Agentic Monitoring) on Kubernetes.
# Idempotent: safe to re-run; existing secrets are never overwritten.
#
# TOIS shares the `model-builder` namespace and reuses the existing
# claude-subscription-gateway (already deployed there by
# transpara/model-builder-install). Model Builder MUST be installed on
# this cluster before running this script — the gateway + its API key
# secret come from that install.
#
# Self-contained: run it next to a deploy/k8s directory (a clone of
# transpara/tois-install or transpara/operational-intelligence-service)
# and it uses those manifests; run it standalone and it fetches them
# from the public transpara/tois-install repo.
#
# Usage:
#   ./install-tois.sh                         # run interactively
#   ./install-tois.sh --rotate-secrets        # re-prompt Transpara creds
#
# Images pull anonymously from registry.transpara.com — no registry
# credentials needed.
set -euo pipefail

NS=model-builder
MANIFEST_TARBALL="https://github.com/transpara/tois-install/archive/refs/heads/main.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROTATE=false
for arg in "$@"; do
  case "$arg" in
    --rotate-secrets) ROTATE=true ;;
    *) echo "Unknown flag: $arg (supported: --rotate-secrets)" >&2; exit 1 ;;
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
  # k3s installs kubectl with a root-owned kubeconfig
  KUBECTL="sudo kubectl"
elif command -v kubectl >/dev/null 2>&1 && sudo kubectl get nodes >/dev/null 2>&1; then
  KUBECTL="sudo kubectl"
fi
[ -n "$KUBECTL" ] || die "no working kubectl. Install Model Builder first (which installs k3s if needed), then re-run this script."

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

# ── Transpara platform credentials ───────────────────────────────────────
say "Transpara platform credentials"
if $KUBECTL -n "$NS" get secret tois-secrets >/dev/null 2>&1 && [ "$ROTATE" != true ]; then
  echo "tois-secrets exists; keeping it (re-run with --rotate-secrets to overwrite)"
else
  if [ ! -t 0 ]; then
    die "no interactive terminal and no existing tois-secrets. Create it manually or run this script interactively."
  fi
  echo "TOIS writes run briefs + per-finding comments to tGraph as a Transpara user."
  echo "Enter the credentials for that user (typically 'tai')."
  read -rp "Transpara username [tai]: " TP_USER
  TP_USER="${TP_USER:-tai}"
  read -rsp "Transpara password: " TP_PASS; echo
  [ -n "$TP_PASS" ] || die "password is required"
  $KUBECTL -n "$NS" create secret generic tois-secrets \
    --from-literal=TRANSPARA_USERNAME="$TP_USER" \
    --from-literal=TRANSPARA_PASSWORD="$TP_PASS" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  echo "tois-secrets written"
fi

# ── deploy ───────────────────────────────────────────────────────────────
say "Applying manifests"
$KUBECTL apply -k "$REPO_ROOT/deploy/k8s/"

say "Waiting for rollouts (first image pulls can take a few minutes)"
$KUBECTL -n "$NS" rollout status deploy/tois --timeout=300s
$KUBECTL -n "$NS" rollout status deploy/tois-ui --timeout=180s

# ── health checks ────────────────────────────────────────────────────────
say "Health checks"
$KUBECTL -n "$NS" exec deploy/tois -- python -c \
  "import urllib.request; urllib.request.urlopen('http://localhost:8788/health', timeout=10)" \
  >/dev/null && echo "tois /health ok" || die "tois /health failed"

# tois-ui uses nginx-unprivileged (no shell tools). Probe via the tois pod
# reaching the tois-ui Service.
$KUBECTL -n "$NS" exec deploy/tois -- python -c \
  "import urllib.request; urllib.request.urlopen('http://tois-ui/', timeout=10)" \
  >/dev/null && echo "tois-ui ok" || die "tois-ui probe failed"

# End-to-end wire checks: the settings API's test-gateway + test-transpara
# endpoints exercise the exact same paths agents use at runtime, so a green
# response here proves TOIS can actually do useful work.
say "End-to-end wire checks"
GATEWAY_PROBE=$($KUBECTL -n "$NS" exec deploy/tois -- python -c \
  "import json,urllib.request; r=urllib.request.urlopen(urllib.request.Request('http://localhost:8788/api/admin/settings/test-gateway', data=b'{}', method='POST', headers={'Content-Type':'application/json'}), timeout=30); print(r.read().decode())")
echo "  gateway probe: $GATEWAY_PROBE"
echo "$GATEWAY_PROBE" | grep -q '"ok":[ ]*true' || warn "gateway probe failed; the tois pod is running but cannot reach the LLM. Check gateway pod + subscription login."

TP_PROBE=$($KUBECTL -n "$NS" exec deploy/tois -- python -c \
  "import json,urllib.request; r=urllib.request.urlopen(urllib.request.Request('http://localhost:8788/api/admin/settings/test-transpara', data=b'{}', method='POST', headers={'Content-Type':'application/json'}), timeout=30); print(r.read().decode())")
echo "  transpara probe: $TP_PROBE"
echo "$TP_PROBE" | grep -q '"ok":[ ]*true' || warn "transpara probe failed; TOIS cannot log into tGraph. Re-run with --rotate-secrets if credentials are wrong."

# ── summary ──────────────────────────────────────────────────────────────
NODE_IP=$($KUBECTL get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
say "Done"
echo "UI:            http://$NODE_IP:30788"
echo "Rotate creds:  $0 --rotate-secrets"
echo "Rollout new image after CI pushes to Harbor:"
echo "               $KUBECTL -n $NS rollout restart deploy/tois deploy/tois-ui"
