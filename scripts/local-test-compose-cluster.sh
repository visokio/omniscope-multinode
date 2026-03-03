#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# local-test-compose-cluster.sh — Run the full Omniscope multi-node cluster
#
# What this starts:
#   - omniscope-editor   (port 9090) — editor cluster, full read/write
#   - omniscope-viewer-1 (no direct port) ─┐
#   - omniscope-viewer-2 (no direct port)  ├── viewer cluster, read-only
#   - openresty          (port 9091) — OpenResty sticky session router for viewers
#   - keycloak           (port 9900) — OIDC/SSO authentication
#   - keycloak-db        (internal)  — Keycloak's PostgreSQL
#
# Usage:
#   ./scripts/local-test-compose-cluster.sh
#
# Requirements:
#   - visokio/omniscope:latest pulled (docker pull --platform=linux/amd64 visokio/omniscope:latest)
#   - Editor licence: any *.lic file in cluster-data/editor/licence/
#   - Viewer licence: any *.lic file in cluster-data/viewer/licence/
#
# cluster-data/ contains only committed bootstrap files (config.xml, serverkey,
# etc.) and licence placeholders. All runtime state is written to cluster-test/
# and is destroyed when you run cluster-test/delete.sh.
#
# ⚠️  Every invocation destroys the previous cluster-test/ folder and all data
#     inside it. This is a clean-slate test tool, not a persistent environment.
# ------------------------------------------------------------------------------

set -euo pipefail

log()  { printf "[cluster-test] %s\n" "$*"; }
warn() { printf "[cluster-test] WARNING: %s\n" "$*"; }
err()  { printf "[cluster-test] ERROR: %s\n" "$*" >&2; }
# Ensure runtime bind-mount folders are writable from containers across host OSes.
ensure_runtime_writable() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    chmod -R u+rwX,go+rwX "${path}" 2>/dev/null || \
      warn "Could not fully set writable perms on: ${path}"
  fi
}

# Wait for HTTP endpoint to return any non-000 status code.
# This validates that the service is reachable and responding to requests.
wait_for_http() {
  local name="$1"
  local url="$2"
  local timeout_secs="${3:-120}"
  local sleep_secs="${4:-2}"
  local ok_pattern="${5:-^(2|3)[0-9][0-9]$}"
  local elapsed=0
  local code

  log "Waiting for ${name} at ${url} (timeout ${timeout_secs}s)..."
  while (( elapsed < timeout_secs )); do
    code="$(curl -m 5 -sS -o /dev/null -w '%{http_code}' "${url}" || true)"
    if [[ -n "${code}" && "${code}" =~ ${ok_pattern} ]]; then
      log "${name} is reachable (${url} -> HTTP ${code})"
      return 0
    fi
    sleep "${sleep_secs}"
    elapsed=$((elapsed + sleep_secs))
  done

  err "${name} is not reachable at ${url} after ${timeout_secs}s"
  return 1
}

wait_for_container_health() {
  local name="$1"
  local container="$2"
  local timeout_secs="${3:-120}"
  local sleep_secs="${4:-2}"
  local elapsed=0
  local state

  log "Waiting for ${name} container health (${container}, timeout ${timeout_secs}s)..."
  while (( elapsed < timeout_secs )); do
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container}" 2>/dev/null || true)"
    if [[ "${state}" == "healthy" || "${state}" == "running" ]]; then
      log "${name} container is ${state}"
      return 0
    fi
    sleep "${sleep_secs}"
    elapsed=$((elapsed + sleep_secs))
  done

  err "${name} container is not healthy/running after ${timeout_secs}s (last state: ${state})"
  return 1
}

dump_cluster_diagnostics() {
  warn "Collecting diagnostics from current cluster..."
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  ${COMPOSE_CMD} ps || true
  ${COMPOSE_CMD} logs --tail=120 omniscope-editor || true
  ${COMPOSE_CMD} logs --tail=120 omniscope-viewer-1 || true
  ${COMPOSE_CMD} logs --tail=120 omniscope-viewer-2 || true
  ${COMPOSE_CMD} logs --tail=120 nginx || true
  ${COMPOSE_CMD} logs --tail=120 keycloak || true
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EDITOR_LIC_DIR="${REPO_ROOT}/cluster-data/editor/licence"
VIEWER_LIC_DIR="${REPO_ROOT}/cluster-data/viewer/licence"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.cluster.yml"
OMNISCOPE_IMAGE="visokio/omniscope:latest"

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------

if ! find "${EDITOR_LIC_DIR}" -maxdepth 1 -type f -name '*.lic' | grep -q .; then
  err "Editor licence not found in: ${EDITOR_LIC_DIR}"
  err "Place your editor licence (with editor seats) in: cluster-data/editor/licence/ (any *.lic filename)"
  exit 1
fi

if ! find "${VIEWER_LIC_DIR}" -maxdepth 1 -type f -name '*.lic' | grep -q .; then
  err "Viewer licence not found in: ${VIEWER_LIC_DIR}"
  err "Place your viewer licence (unlimited viewers) in: cluster-data/viewer/licence/ (any *.lic filename)"
  exit 1
fi

if ! docker image inspect "${OMNISCOPE_IMAGE}" >/dev/null 2>&1; then
  err "Image '${OMNISCOPE_IMAGE}' not found locally."
  err "Pull it first: docker pull --platform=linux/amd64 ${OMNISCOPE_IMAGE}"
  exit 2
fi

# ------------------------------------------------------------------------------
# Remove any existing cluster containers to avoid conflicts.
# Filter by the fixed label visokio.cluster=omniscope which is set on every
# service in the compose file. This catches all previous runs regardless of
# project name, timestamp, or which path the script was launched from.
# ------------------------------------------------------------------------------
EXISTING_IDS=$(docker ps -aq --filter "label=visokio.cluster=omniscope")
if [[ -n "${EXISTING_IDS// /}" ]]; then
  log "Removing existing cluster containers..."
  # shellcheck disable=SC2086
  docker rm -f ${EXISTING_IDS} >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------
# Destroy any previous cluster-test/ folder
# ⚠️  All previous runtime data (projects, logs, Keycloak DB) is deleted here.
# ------------------------------------------------------------------------------
TEST_DIR="${REPO_ROOT}/cluster-test"
if [[ -d "${TEST_DIR}" ]]; then
  rm -rf "${TEST_DIR}" 2>/dev/null || {
    warn "Could not fully remove cluster-test/ (root-owned files). Run: sudo rm -rf ${TEST_DIR}"
  }
fi

# ------------------------------------------------------------------------------
# Create cluster-test/ for this run.
# Everything here is ephemeral — destroyed by cluster-test/delete.sh:
#   - editor/omniscope-server/           seeded from cluster-data/ bootstrap files
#   - viewer/omniscope-server/           seeded from cluster-data/ bootstrap files
#   - viewer/nodes/node-X/logs/          per-node log directories
#   - viewer/nodes/node-X/error reports/ per-node error report directories
#   - shared/files/                      shared projects folder (editor + all viewers)
#   - keycloak/data/                     rebuilt from realm.json on every run
# ------------------------------------------------------------------------------
mkdir -p "${TEST_DIR}"

TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
PROJECT_NAME="omniscope-cluster-${TIMESTAMP}"

# ------------------------------------------------------------------------------
# Seed editor omniscope-server from committed bootstrap files
# ------------------------------------------------------------------------------
export EDITOR_OMNISCOPE_SERVER="${TEST_DIR}/editor/omniscope-server"
mkdir -p "${EDITOR_OMNISCOPE_SERVER}"
cp -r "${REPO_ROOT}/cluster-data/editor/omniscope-server/." "${EDITOR_OMNISCOPE_SERVER}/"
log "Seeded editor omniscope-server from cluster-data/"

# ------------------------------------------------------------------------------
# Seed viewer omniscope-server from committed bootstrap files
# (shared across all viewer nodes)
# ------------------------------------------------------------------------------
export VIEWER_OMNISCOPE_SERVER="${TEST_DIR}/viewer/omniscope-server"
mkdir -p "${VIEWER_OMNISCOPE_SERVER}"
cp -r "${REPO_ROOT}/cluster-data/viewer/omniscope-server/." "${VIEWER_OMNISCOPE_SERVER}/"
log "Seeded viewer omniscope-server from cluster-data/"

# ------------------------------------------------------------------------------
# Per-viewer-node log and error report directories (each node gets its own).
# JVM tmp goes to files/.tmp (inside the same files mount) —
# same device, so atomic rename() for project saves works correctly.
# ------------------------------------------------------------------------------
export VIEWER_NODE_1_LOGS="${TEST_DIR}/viewer/nodes/node-1/logs"
export VIEWER_NODE_2_LOGS="${TEST_DIR}/viewer/nodes/node-2/logs"
export VIEWER_NODE_1_ERROR_REPORTS="${TEST_DIR}/viewer/nodes/node-1/error reports"
export VIEWER_NODE_2_ERROR_REPORTS="${TEST_DIR}/viewer/nodes/node-2/error reports"
mkdir -p \
  "${VIEWER_NODE_1_LOGS}" \
  "${VIEWER_NODE_2_LOGS}" \
  "${VIEWER_NODE_1_ERROR_REPORTS}" \
  "${VIEWER_NODE_2_ERROR_REPORTS}"

# ------------------------------------------------------------------------------
# Shared files directory mounted into /home/omniscope/omniscope-server/files on editor and viewers.
# files/.tmp is JVM temp dir, kept inside the same mount as projects for atomic rename.
# ------------------------------------------------------------------------------
export SHARED_FILES_DIR="${TEST_DIR}/shared/files"
mkdir -p "${SHARED_FILES_DIR}" "${SHARED_FILES_DIR}/.tmp"
cp -r "${REPO_ROOT}/cluster-data/shared/files/." "${SHARED_FILES_DIR}/"
mkdir -p "${SHARED_FILES_DIR}/.tmp"
# Per-node JVM temp subdirs (all inside the same shared files mount).
mkdir -p \
  "${SHARED_FILES_DIR}/.tmp/editor" \
  "${SHARED_FILES_DIR}/.tmp/viewer-1" \
  "${SHARED_FILES_DIR}/.tmp/viewer-2"
log "Seeded shared/files from cluster-data/"

# ------------------------------------------------------------------------------
# Keycloak database — rebuilt from realm.json on every run.
# ------------------------------------------------------------------------------
export KEYCLOAK_DATA="${TEST_DIR}/keycloak/data"
mkdir -p "${KEYCLOAK_DATA}"

# ------------------------------------------------------------------------------
# Ensure all runtime bind mounts are writable before containers start.
# ------------------------------------------------------------------------------
ensure_runtime_writable "${EDITOR_OMNISCOPE_SERVER}"
ensure_runtime_writable "${VIEWER_OMNISCOPE_SERVER}"
ensure_runtime_writable "${VIEWER_NODE_1_LOGS}"
ensure_runtime_writable "${VIEWER_NODE_2_LOGS}"
ensure_runtime_writable "${VIEWER_NODE_1_ERROR_REPORTS}"
ensure_runtime_writable "${VIEWER_NODE_2_ERROR_REPORTS}"
ensure_runtime_writable "${SHARED_FILES_DIR}"
ensure_runtime_writable "${KEYCLOAK_DATA}"

# ------------------------------------------------------------------------------
# Write delete.sh — stops containers and destroys this entire cluster-test/ folder
# ------------------------------------------------------------------------------
cat > "${TEST_DIR}/delete.sh" <<DELETESCRIPT
#!/usr/bin/env bash
# Destroy the cluster — stops all containers and deletes cluster-test/
export KEYCLOAK_DATA="${KEYCLOAK_DATA}"
export EDITOR_OMNISCOPE_SERVER="${EDITOR_OMNISCOPE_SERVER}"
export VIEWER_OMNISCOPE_SERVER="${VIEWER_OMNISCOPE_SERVER}"
export SHARED_FILES_DIR="${SHARED_FILES_DIR}"
export VIEWER_NODE_1_LOGS="${VIEWER_NODE_1_LOGS}"
export VIEWER_NODE_2_LOGS="${VIEWER_NODE_2_LOGS}"
export VIEWER_NODE_1_ERROR_REPORTS="${VIEWER_NODE_1_ERROR_REPORTS}"
export VIEWER_NODE_2_ERROR_REPORTS="${VIEWER_NODE_2_ERROR_REPORTS}"
docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" down --remove-orphans
docker network prune -f
rm -rf "${TEST_DIR}"
echo "Cluster destroyed and cluster-test/ removed."
DELETESCRIPT
chmod +x "${TEST_DIR}/delete.sh"

# ------------------------------------------------------------------------------
# Start the cluster
# Run from REPO_ROOT so relative paths in docker-compose.cluster.yml
# (licence files, realm-export, nginx.conf) resolve correctly.
# ------------------------------------------------------------------------------
cd "${REPO_ROOT}"

log "Starting cluster (project: ${PROJECT_NAME})..."
start_ok=false
for attempt in 1 2; do
  if docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" up -d; then
    start_ok=true
    break
  fi
  warn "docker compose up failed on attempt ${attempt}; retrying with clean down..."
  docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" down --remove-orphans >/dev/null 2>&1 || true
  sleep 2
done
if [[ "${start_ok}" != "true" ]]; then
  err "Failed to start cluster after retries."
  exit 4
fi

COMPOSE_CMD="docker compose -f ${COMPOSE_FILE} -p ${PROJECT_NAME}"
KEYCLOAK_CONTAINER="${PROJECT_NAME}-keycloak-1"

# ------------------------------------------------------------------------------
# Disable SSL requirement on the Keycloak master realm.
# start-dev should do this automatically but doesn't always — patch it directly.
# kcadm runs inside the Keycloak container, so it reaches Keycloak on its
# internal port 80, not via the external OpenResty proxy on 9900.
# ------------------------------------------------------------------------------
log "Patching Keycloak master realm: disabling SSL requirement..."
for i in {1..10}; do
  if docker exec "${KEYCLOAK_CONTAINER}" \
      /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:80 --realm master \
      --user admin --password admin >/dev/null 2>&1; then
    docker exec "${KEYCLOAK_CONTAINER}" \
      /opt/keycloak/bin/kcadm.sh update realms/master \
      -s sslRequired=NONE >/dev/null 2>&1 && \
      log "Keycloak master realm SSL disabled." && break
  fi
  sleep 3
done

# ------------------------------------------------------------------------------
# Post-start readiness checks
# Fail fast with diagnostics if any critical endpoint is not reachable.
# Note: editor is NOT behind OpenResty/nginx. It is checked directly on :9090.
# OpenResty health check validates only the viewer/keycloak ingress layer.
# ------------------------------------------------------------------------------
if ! wait_for_http "Keycloak" "http://keycloak.localhost:9900"; then
  dump_cluster_diagnostics
  exit 3
fi
if ! wait_for_container_health "Editor" "${PROJECT_NAME}-omniscope-editor-1"; then
  dump_cluster_diagnostics
  exit 3
fi
if ! wait_for_container_health "Viewer-1" "${PROJECT_NAME}-omniscope-viewer-1-1"; then
  dump_cluster_diagnostics
  exit 3
fi
if ! wait_for_container_health "Viewer-2" "${PROJECT_NAME}-omniscope-viewer-2-1"; then
  dump_cluster_diagnostics
  exit 3
fi
if ! wait_for_http "OpenResty edge (viewer/keycloak only)" "http://viewer.localhost:9091/nginx-health"; then
  dump_cluster_diagnostics
  exit 3
fi
if ! wait_for_http "Editor endpoint" "http://editor.localhost:9090" 120 2 '^(2|3)[0-9][0-9]$|^401$'; then
  dump_cluster_diagnostics
  exit 3
fi
if ! wait_for_http "Viewer endpoint" "http://viewer.localhost:9091"; then
  dump_cluster_diagnostics
  exit 3
fi

# ------------------------------------------------------------------------------
# Read OIDC details from source-of-truth configs (cluster-data/) for summary.
# ------------------------------------------------------------------------------
EDITOR_OIDC_LINE="$(grep -m1 '<oidcProviderKeycloak ' "${REPO_ROOT}/cluster-data/editor/omniscope-server/config.xml" || true)"
VIEWER_OIDC_LINE="$(grep -m1 '<oidcProviderKeycloak ' "${REPO_ROOT}/cluster-data/viewer/omniscope-server/config.xml" || true)"
REALM_JSON="${REPO_ROOT}/cluster-data/keycloak/realm-export/realm.json"

EDITOR_ISSUER_URI="$(printf '%s\n' "${EDITOR_OIDC_LINE}" | sed -n 's/.*issuerUri="\([^"]*\)".*/\1/p')"
EDITOR_CLIENT_ID="$(printf '%s\n' "${EDITOR_OIDC_LINE}" | sed -n 's/.*clientId="\([^"]*\)".*/\1/p')"
EDITOR_CLIENT_SECRET="$(printf '%s\n' "${EDITOR_OIDC_LINE}" | sed -n 's/.*clientSecret="\([^"]*\)".*/\1/p')"
EDITOR_LOGIN_MODE="$(printf '%s\n' "${EDITOR_OIDC_LINE}" | sed -n 's/.*loginMode="\([^"]*\)".*/\1/p')"

VIEWER_CLIENT_ID="$(printf '%s\n' "${VIEWER_OIDC_LINE}" | sed -n 's/.*clientId="\([^"]*\)".*/\1/p')"
VIEWER_CLIENT_SECRET="$(printf '%s\n' "${VIEWER_OIDC_LINE}" | sed -n 's/.*clientSecret="\([^"]*\)".*/\1/p')"

# Prefer raw Keycloak client secrets from realm export to avoid showing
# Omniscope's transformed/encrypted-at-rest values from config.xml.
EDITOR_REALM_SECRET="$(awk '
  /"clientId": "omniscope-editor"/ { in_editor=1; next }
  in_editor && /"secret":/ {
    match($0, /"secret":[[:space:]]*"[^"]+"/)
    if (RSTART) {
      s = substr($0, RSTART, RLENGTH)
      sub(/.*"secret":[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  }
' "${REALM_JSON}")"

VIEWER_REALM_SECRET="$(awk '
  /"clientId": "omniscope-viewer"/ { in_viewer=1; next }
  in_viewer && /"secret":/ {
    match($0, /"secret":[[:space:]]*"[^"]+"/)
    if (RSTART) {
      s = substr($0, RSTART, RLENGTH)
      sub(/.*"secret":[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  }
' "${REALM_JSON}")"

if [[ -n "${EDITOR_REALM_SECRET}" ]]; then
  EDITOR_CLIENT_SECRET="${EDITOR_REALM_SECRET}"
fi
if [[ -n "${VIEWER_REALM_SECRET}" ]]; then
  VIEWER_CLIENT_SECRET="${VIEWER_REALM_SECRET}"
fi

if [[ -z "${EDITOR_ISSUER_URI}" ]]; then
  EDITOR_ISSUER_URI="http://keycloak.localhost:9900/realms/visokio/"
fi
if [[ -z "${EDITOR_LOGIN_MODE}" ]]; then
  EDITOR_LOGIN_MODE="IMPLICIT_SSO_ALWAYS"
fi

# ------------------------------------------------------------------------------
# Print summary
# ------------------------------------------------------------------------------
echo
printf '=%.0s' {1..70}; echo
printf "  Omniscope Multi-Node Cluster: started\n"
printf "  Project: %s\n" "${PROJECT_NAME}"
printf '=%.0s' {1..70}; echo
echo

printf -- '-%.0s' {1..70}; echo
printf "  EDITOR\n"
printf -- '-%.0s' {1..70}; echo
printf "  URL:       http://editor.localhost:9090\n"
printf "  Username:  admin\n"
printf "  Password:  admin1234\n"
printf "  Logs:      %s logs -f omniscope-editor\n" "${COMPOSE_CMD}"
printf "  Shell:     docker exec -it %s-omniscope-editor-1 bash\n" "${PROJECT_NAME}"
printf "  Restart:   %s restart omniscope-editor\n" "${COMPOSE_CMD}"
echo

printf -- '-%.0s' {1..70}; echo
printf "  VIEWER CLUSTER (OpenResty sticky load balancer: 2 nodes)\n"
printf -- '-%.0s' {1..70}; echo
printf "  URL:       http://viewer.localhost:9091\n"
printf "  Direct:    http://viewer-node-1.localhost:19091 (viewer-1, bypasses LB)\n"
printf "  Direct:    http://viewer-node-2.localhost:19092 (viewer-2, bypasses LB)\n"
printf "  Username:  admin\n"
printf "  Password:  admin1234\n"
printf "  Logs:      %s logs -f omniscope-viewer-1\n" "${COMPOSE_CMD}"
printf "  Logs:      %s logs -f omniscope-viewer-2\n" "${COMPOSE_CMD}"
printf "  OpenResty: %s logs -f nginx\n" "${COMPOSE_CMD}"
printf "  Shell:     docker exec -it %s-omniscope-viewer-1-1 bash\n" "${PROJECT_NAME}"
printf "  Node logs: %s/viewer/nodes/node-{1,2}/logs/\n" "${TEST_DIR}"
printf "  Err rpts:  %s/viewer/nodes/node-{1,2}/error reports/\n" "${TEST_DIR}"
echo

printf -- '-%.0s' {1..70}; echo
printf "  KEYCLOAK — OIDC/SSO Authentication\n"
printf -- '-%.0s' {1..70}; echo
printf "  URL:       http://keycloak.localhost:9900\n"
printf "  Admin:     admin / admin\n"
printf "  Realm:     visokio (auto-imported on first start)\n"
printf "  Logs:      %s logs -f keycloak\n" "${COMPOSE_CMD}"
echo

printf -- '-%.0s' {1..70}; echo
printf "  OIDC CONFIGURATION (pre-configured — for reference only)\n"
printf -- '-%.0s' {1..70}; echo
printf "  Both nodes are already configured to use Keycloak. No setup needed.\n"
printf "\n"
printf "  Issuer URI:   %s\n" "${EDITOR_ISSUER_URI}"
printf "  Login mode:   %s\n" "${EDITOR_LOGIN_MODE}"
printf "\n"
printf "  Editor node   http://editor.localhost:9090\n"
printf "    Client ID:      %s\n" "${EDITOR_CLIENT_ID}"
printf "    Client secret:  %s\n" "${EDITOR_CLIENT_SECRET}"
printf "\n"
printf "  Viewer nodes  http://viewer.localhost:9091\n"
printf "    Direct:     http://viewer-node-1.localhost:19091\n"
printf "    Direct:     http://viewer-node-2.localhost:19092\n"
printf "    Client ID:      %s\n" "${VIEWER_CLIENT_ID}"
printf "    Client secret:  %s\n" "${VIEWER_CLIENT_SECRET}"
printf "    Note:           Both viewer nodes share this client/secret.\n"
printf "\n"
printf "  Roles -> Omniscope permission groups:\n"
printf "    editor-role  -> Project editor  (editor node)\n"
printf "    viewer-role  -> Report viewer   (viewer nodes)\n"
echo

printf -- '-%.0s' {1..70}; echo
printf "  TEST USERS\n"
printf -- '-%.0s' {1..70}; echo
printf "  editor-user-a / editor123  -> editor-role  -> http://editor.localhost:9090\n"
printf "  editor-user-b / editor123  -> editor-role  -> http://editor.localhost:9090\n"
printf "  viewer-user-a / viewer123  -> viewer-role  -> http://viewer.localhost:9091\n"
printf "  viewer-user-b / viewer123  -> viewer-role  -> http://viewer.localhost:9091\n"
printf "  viewer-user-c / viewer123  -> viewer-role  -> http://viewer.localhost:9091\n"
echo

printf -- '-%.0s' {1..70}; echo
printf "  DESTROY CLUSTER\n"
printf -- '-%.0s' {1..70}; echo
printf "  %s/delete.sh\n" "${TEST_DIR}"
echo

printf '=%.0s' {1..70}; echo
printf "  NOTE: Keycloak may take 30-60s to become available.\n"
printf "  NOTE: All runtime state is in cluster-test/ — destroyed when you run delete.sh\n"
printf '=%.0s' {1..70}; echo
echo
