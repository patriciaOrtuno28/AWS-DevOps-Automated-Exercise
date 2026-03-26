#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  05-setup-pipeline.sh
#  Configura el pipeline CI/CD:
#    1. Construye el ARN del GitHub role
#    2. Muestra el secreto a añadir en GitHub
#    3. Verifica que los workflows esten en el repo
#    4. Hace el primer push de la imagen a ECR
#       (necesario para que ECS pueda arrancar)
#
#  Archivos del pipeline en: .github/workflows/
#  App en: app/
#
#  Uso:
#    chmod +x 05-setup-pipeline.sh
#    ./05-setup-pipeline.sh
#
#  Configuracion en: config.env
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
echo -e "${BOLD}║      05 — Pipeline setup                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GITHUB_OIDC_ROLE_NAME}"

log_info "GitHub repo : ${GITHUB_ORG}/${GITHUB_REPO}"
log_info "Deploy role : ${ROLE_ARN}"

# ── 1. Verify IAM role exists ─────────────────
log_step "1/3 — Verifying IAM role for GitHub Actions..."

ROLE_EXISTS=$(aws iam get-role \
  --role-name "${GITHUB_OIDC_ROLE_NAME}" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")

[ "$ROLE_EXISTS" = "NOT_FOUND" ] && \
  log_error "Role not found. Run 01-setup-iam.sh first."

log_success "Role verified: ${ROLE_ARN}"

# ── 2. GitHub secret instructions ────────────
log_step "2/3 — GitHub Secret configuration..."

echo ""
echo -e "${YELLOW}${BOLD}  ACTION REQUIRED — add this secret to your GitHub repo:${NC}"
echo ""
echo -e "  ${BOLD}Go to:${NC}"
echo -e "  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/settings/secrets/actions"
echo ""
echo -e "  ${BOLD}Create a new secret:${NC}"
echo -e "  ${CYAN}Name :${NC}  AWS_DEPLOY_ROLE_ARN"
echo -e "  ${CYAN}Value:${NC}  ${ROLE_ARN}"
echo ""
read -p "$(echo -e "  ${BOLD}Press Enter once you have added the secret...${NC}")" _

# ── 3. Verify workflow files ──────────────────
log_step "3/3 — Verifying workflow files in repo..."

DEPLOY_WF="${SCRIPT_DIR}/.github/workflows/deploy.yml"
PR_WF="${SCRIPT_DIR}/.github/workflows/pr-check.yml"

[ ! -f "$DEPLOY_WF" ] && \
  log_error "Missing: .github/workflows/deploy.yml — copy it from the outputs folder"
[ ! -f "$PR_WF" ] && \
  log_error "Missing: .github/workflows/pr-check.yml — copy it from the outputs folder"

log_success "deploy.yml found"
log_success "pr-check.yml found"

# Verify app files
APP_DIR="${SCRIPT_DIR}/app"
[ ! -f "${APP_DIR}/index.js" ]      && log_error "Missing: app/index.js"
[ ! -f "${APP_DIR}/package.json" ]  && log_error "Missing: app/package.json"
[ ! -f "${APP_DIR}/Dockerfile" ]    && log_error "Missing: app/Dockerfile"
[ ! -f "${APP_DIR}/index.test.js" ] && log_error "Missing: app/index.test.js"

log_success "App files found: index.js, package.json, Dockerfile, index.test.js"

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  05 — Pipeline setup completed           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "GitHub role ARN : ${ROLE_ARN}"
log_success "Secret name     : AWS_DEPLOY_ROLE_ARN"
log_success "Workflows       : deploy.yml + pr-check.yml"
echo ""
echo -e "${CYAN}${BOLD}── How to trigger the first deploy ─────────────────${NC}"
echo ""
echo -e "  ${BOLD}1. Commit and push everything to main:${NC}"
echo -e "     ${YELLOW}git add .${NC}"
echo -e "     ${YELLOW}git commit -m 'feat: initial app and pipeline setup'${NC}"
echo -e "     ${YELLOW}git push origin main${NC}"
echo ""
echo -e "  ${BOLD}2. Watch the pipeline run:${NC}"
echo -e "     https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/actions"
echo -e "     ${YELLOW}→ 'Build, test and deploy' workflow should appear${NC}"
echo -e "     ${YELLOW}→ Jobs: test → build-and-deploy${NC}"
echo -e "     ${YELLOW}→ Total time: ~3-4 minutes${NC}"
echo ""
echo -e "  ${BOLD}3. Verify the deploy:${NC}"
echo -e "     ECS → Clusters → devops-exercise-cluster → Services"
echo -e "     ${YELLOW}→ Running tasks: 2 (was 0 before)${NC}"
echo -e "     ${YELLOW}→ Deployments tab: shows the rolling update completing${NC}"
echo ""
echo -e "  ${BOLD}4. Visit the app:${NC}"
if [ -n "${ALB_DNS:-}" ]; then
  echo -e "     ${YELLOW}→ http://${ALB_DNS}${NC}"
  echo -e "     ${YELLOW}→ http://${ALB_DNS}/health${NC}"
  echo -e "     ${YELLOW}→ http://${ALB_DNS}/info${NC}"
else
  echo -e "     ${YELLOW}→ Check config.env for ALB_DNS after running 04-setup-ecs.sh${NC}"
fi
echo ""
echo -e "  ${BOLD}5. ECR image scan results:${NC}"
echo -e "     ECR → Repositories → devops-exercise-app → Images"
echo -e "     ${YELLOW}→ Click the image SHA → View scan results${NC}"
echo -e "     ${YELLOW}→ Shows CVEs found in the image layers${NC}"
echo ""