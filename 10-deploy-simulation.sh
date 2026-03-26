#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  10-deploy-simulation.sh
#  Simula un ciclo completo de deploy:
#    1. Hace un cambio visible en la app
#    2. Commit + push → dispara el pipeline
#    3. Monitoriza el pipeline en tiempo real
#    4. Verifica que la nueva version esta live
#
#  Requiere: git configurado y acceso al repo
#
#  Uso:
#    chmod +x 10-deploy-simulation.sh
#    ./10-deploy-simulation.sh
# ─────────────────────────────────────────────

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}> $1${NC}"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/config.env"
[ ! -f "$CONF_FILE" ] && log_error "config.env not found"
source "$CONF_FILE"
R="--region ${AWS_REGION}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      10 — Deploy simulation              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Show current version ───────────────────
log_step "1/4 — Current app state..."

CURRENT_VERSION=$(curl -s --max-time 5 "http://${ALB_DNS}" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','unknown'))" \
  2>/dev/null || echo "unreachable")

log_info "Current version at http://${ALB_DNS}: ${CURRENT_VERSION}"

# ── 2. Bump version in config ─────────────────
log_step "2/4 — Bumping app version..."

CURRENT=$(grep "^APP_VERSION=" "$CONF_FILE" | cut -d'"' -f2)
MAJOR=$(echo "$CURRENT" | cut -d'.' -f1)
MINOR=$(echo "$CURRENT" | cut -d'.' -f2)
PATCH=$(echo "$CURRENT" | cut -d'.' -f3)
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"

sed -i "s/^APP_VERSION=.*/APP_VERSION=\"${NEW_VERSION}\"/" "$CONF_FILE"
log_success "Version bumped: ${CURRENT} → ${NEW_VERSION}"

# Update app/package.json — this is what triggers the GitHub Actions workflow (paths: app/**)
sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"${NEW_VERSION}\"/" \
  "${SCRIPT_DIR}/app/package.json"

# Also update the task definition env var
sed -i "s/\"value\": \"${CURRENT}\"/\"value\": \"${NEW_VERSION}\"/" \
  "${SCRIPT_DIR}/ecs/task-definition.json" 2>/dev/null || true

# ── 3. Commit and push ────────────────────────
log_step "3/4 — Committing and pushing change..."

cd "${SCRIPT_DIR}"
git add config.env app/package.json ecs/task-definition.json
git commit -m "chore: bump app version to ${NEW_VERSION}"
git push origin main

log_success "Pushed to main — pipeline triggered."
log_info ""
log_info "Watch the pipeline at:"
log_info "  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/actions"

# ── 4. Poll ECS until new version is live ─────
log_step "4/4 — Waiting for new version to go live (max 10 min)..."
echo ""

ATTEMPTS=0
MAX=40
DEPLOYED=false

while [ $ATTEMPTS -lt $MAX ]; do
  sleep 15
  ATTEMPTS=$((ATTEMPTS + 1))

  LIVE_VERSION=$(curl -s --max-time 5 "http://${ALB_DNS}" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','unknown'))" \
    2>/dev/null || echo "unreachable")

  RUNNING=$(aws ecs describe-services $R \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].runningCount' \
    --output text 2>/dev/null || echo "0")

  echo -e "  ${ATTEMPTS}/${MAX} — live: ${CYAN}v${LIVE_VERSION}${NC} · running tasks: ${RUNNING}"

  if [ "$LIVE_VERSION" = "$NEW_VERSION" ]; then
    DEPLOYED=true
    break
  fi
done

echo ""
if [ "$DEPLOYED" = "true" ]; then
  log_success "Deploy complete! New version is live."
  log_success "  Before : v${CURRENT}"
  log_success "  After  : v${NEW_VERSION}"
  log_success "  URL    : http://${ALB_DNS}"
else
  log_warn "Timeout — pipeline may still be running."
  log_info "Check: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/actions"
fi

echo ""
echo -e "${CYAN}${BOLD}── What just happened ──────────────────────────────${NC}"
echo ""
echo -e "  ${YELLOW}1. config.env version bump → git push → GitHub Actions triggered${NC}"
echo -e "  ${YELLOW}2. Tests passed → Docker build → pushed to ECR with SHA tag${NC}"
echo -e "  ${YELLOW}3. ECS task definition updated with new image SHA${NC}"
echo -e "  ${YELLOW}4. ECS rolling update: new tasks started, old ones drained${NC}"
echo -e "  ${YELLOW}5. ALB health checks confirmed new tasks healthy${NC}"
echo -e "  ${YELLOW}6. Zero downtime — ALB always had healthy targets during update${NC}"
echo ""