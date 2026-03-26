#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  11-rollback-simulation.sh
#  Simula un fallo en produccion y rollback:
#    1. Introduce un bug que rompe el /health
#    2. Push → pipeline despliega la version rota
#    3. ECS detecta health check fallido
#    4. Rollback manual a la revision anterior
#    5. Verifica que el servicio se recupera
#
#  Uso:
#    chmod +x 11-rollback-simulation.sh
#    ./11-rollback-simulation.sh
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
echo -e "${BOLD}║      11 — Rollback simulation            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}  This script intentionally breaks the app to demonstrate rollback.${NC}"
echo -e "${RED}  The app will be unavailable for ~2-3 minutes.${NC}"
echo ""
read -p "$(echo -e "${YELLOW}[INPUT]${NC} Type 'break' to continue: ")" CONFIRM
[ "$CONFIRM" != "break" ] && { log_info "Cancelled."; exit 0; }

# ── 1. Record current good state ─────────────
log_step "1/5 — Recording current good state..."

GOOD_VERSION=$(grep "^APP_VERSION=" "$CONF_FILE" | cut -d'"' -f2)
GOOD_TASK_ARN=$(aws ecs describe-services $R \
  --cluster "${ECS_CLUSTER_NAME}" \
  --services "${ECS_SERVICE_NAME}" \
  --query 'services[0].taskDefinition' \
  --output text)
GOOD_REVISION=$(echo "$GOOD_TASK_ARN" | awk -F':' '{print $NF}')

log_success "Current good revision: ${ECS_TASK_FAMILY}:${GOOD_REVISION}"
log_success "Current good version : ${GOOD_VERSION}"

# ── 2. Inject bug ─────────────────────────────
log_step "2/5 — Injecting bug (breaking /health endpoint)..."

BROKEN_HEALTH='app.get("/health", (req, res) => { res.status(500).json({ status: "broken" }); });'

cp "${SCRIPT_DIR}/app/index.js" "${SCRIPT_DIR}/app/index.js.bak"

INDEX_JS_WIN=$(cygpath -w "${SCRIPT_DIR}/app/index.js")
python3 - << PYEOF
with open(r'${INDEX_JS_WIN}', 'r') as f:
    content = f.read()
content = content.replace(
    'app.get(\'/health\', (req, res) => {\n  res.json({ status: \'ok\', version: VERSION });\n});',
    'app.get(\'/health\', (req, res) => {\n  res.status(500).json({ status: \'broken\', error: \'intentional bug\' });\n});'
)
with open(r'${INDEX_JS_WIN}', 'w') as f:
    f.write(content)
print("Bug injected")
PYEOF

log_warn "Bug injected: /health now returns 500"
log_info "Pushing broken version..."

cd "${SCRIPT_DIR}"
git add app/index.js
git commit -m "bug: intentional broken health check for rollback demo"
git push origin main

log_warn "Broken version pushed — pipeline will deploy it."
log_info "Watch: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/actions"

# ── 3. Watch ECS detect the failure ──────────
log_step "3/5 — Watching ECS detect unhealthy tasks..."
echo ""
log_info "ECS health check: GET /health must return 200"
log_info "Our broken version returns 500 — tasks will be marked unhealthy"
echo ""

ATTEMPTS=0
UNHEALTHY_SEEN=false
while [ $ATTEMPTS -lt 20 ]; do
  sleep 15
  ATTEMPTS=$((ATTEMPTS + 1))

  RUNNING=$(aws ecs describe-services $R \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].runningCount' --output text 2>/dev/null || echo "?")
  PENDING=$(aws ecs describe-services $R \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].pendingCount' --output text 2>/dev/null || echo "?")

  echo -e "  ${ATTEMPTS}/20 — running: ${RUNNING} · pending: ${PENDING}"

  if [ "$RUNNING" = "0" ] || [ "$PENDING" -gt 2 ] 2>/dev/null; then
    UNHEALTHY_SEEN=true
    log_warn "Failure detected — ECS is struggling to keep tasks healthy."
    break
  fi
done

# ── 4. Rollback ───────────────────────────────
log_step "4/5 — Rolling back to revision ${GOOD_REVISION}..."

aws ecs update-service $R \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service "${ECS_SERVICE_NAME}" \
  --task-definition "${ECS_TASK_FAMILY}:${GOOD_REVISION}" \
  --force-new-deployment \
  --output table

log_success "Rollback initiated — ECS will now replace tasks with revision ${GOOD_REVISION}"

# Restore the good index.js
mv "${SCRIPT_DIR}/app/index.js.bak" "${SCRIPT_DIR}/app/index.js"
cd "${SCRIPT_DIR}"
git add app/index.js
git commit -m "fix: revert broken health check"
git push origin main
log_success "Good version restored in repo."

# ── 5. Wait for recovery ──────────────────────
log_step "5/5 — Waiting for service to recover..."
echo ""

ATTEMPTS=0
RECOVERED=false
while [ $ATTEMPTS -lt 24 ]; do
  sleep 15
  ATTEMPTS=$((ATTEMPTS + 1))

  HEALTH=$(curl -s --max-time 5 "http://${ALB_DNS}/health" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','unknown'))" \
    2>/dev/null || echo "unreachable")

  RUNNING=$(aws ecs describe-services $R \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")

  echo -e "  ${ATTEMPTS}/24 — /health: ${CYAN}${HEALTH}${NC} · running: ${RUNNING}"

  if [ "$HEALTH" = "ok" ] && [ "$RUNNING" -ge 1 ] 2>/dev/null; then
    RECOVERED=true
    break
  fi
done

echo ""
if [ "$RECOVERED" = "true" ]; then
  log_success "Service recovered — /health returns ok"
  log_success "Running tasks: ${RUNNING}"
else
  log_warn "Recovery still in progress — check ECS console."
fi

echo ""
echo -e "${CYAN}${BOLD}── What just happened ──────────────────────────────${NC}"
echo ""
echo -e "  ${YELLOW}1. Broke /health — it returned 500 instead of 200${NC}"
echo -e "  ${YELLOW}2. Pipeline deployed the broken image to ECS${NC}"
echo -e "  ${YELLOW}3. ECS health check failed — ALB marked tasks unhealthy${NC}"
echo -e "  ${YELLOW}4. Manual rollback: aws ecs update-service --task-definition :${GOOD_REVISION}${NC}"
echo -e "  ${YELLOW}5. ECS replaced broken tasks with the known-good revision${NC}"
echo -e "  ${YELLOW}6. Service recovered without redeploying from scratch${NC}"
echo ""
echo -e "  ${BOLD}Key insight:${NC}"
echo -e "  ${YELLOW}ECS keeps all previous task definition revisions.${NC}"
echo -e "  ${YELLOW}A rollback is just pointing the service at a previous revision.${NC}"
echo -e "  ${YELLOW}No rebuild, no pipeline needed — takes ~2 minutes.${NC}"
echo ""
