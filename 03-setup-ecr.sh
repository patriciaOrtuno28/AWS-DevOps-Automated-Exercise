#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  03-setup-ecr.sh
#  Crea el registro de imagenes Docker:
#    1. ECR repository privado
#    2. Lifecycle policy (max 10 imagenes, limpiar untagged)
#    3. Scan on push activado (vulnerabilidades)
#    4. Muestra el comando de push para referencia
#
#  ECR es el equivalente de DockerHub pero privado
#  y dentro de tu cuenta AWS. GitHub Actions hara
#  push aqui — ECS Fargate hara pull desde aqui.
#
#  JSON templates en: ecr/
#
#  Uso:
#    chmod +x 03-setup-ecr.sh
#    ./03-setup-ecr.sh
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
ECR_DIR="${SCRIPT_DIR}/ecr"

[ ! -f "$CONF_FILE" ] && log_error "config.env not found"
[ ! -d "$ECR_DIR"   ] && log_error "ecr/ directory not found"
[ ! -f "${ECR_DIR}/lifecycle-policy.json" ] && \
  log_error "Missing template: ecr/lifecycle-policy.json"

source "$CONF_FILE"
R="--region ${AWS_REGION}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      03 — ECR setup                      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

log_info "Repository  : ${ECR_REPO_NAME}"
log_info "URI         : ${ECR_URI}"
log_info "Scan on push: ${ECR_SCAN_ON_PUSH}"
log_info "Max images  : ${ECR_MAX_IMAGES}"

# ── 1. ECR repository ─────────────────────────
log_step "1/3 — Creating ECR repository..."

EXISTING_REPO=$(aws ecr describe-repositories $R \
  --repository-names "${ECR_REPO_NAME}" \
  --query 'repositories[0].repositoryName' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_REPO" != "NOT_FOUND" ]; then
  log_warn "Repository already exists: ${ECR_REPO_NAME}"
else
  aws ecr create-repository $R \
    --repository-name "${ECR_REPO_NAME}" \
    --image-scanning-configuration scanOnPush="${ECR_SCAN_ON_PUSH}" \
    --image-tag-mutability MUTABLE \
    --output table
  log_success "ECR repository created: ${ECR_URI}"
  log_info "  Scan on push : enabled (detects CVEs on every push)"
  log_info "  Tag mutability: MUTABLE (allows reusing tags like 'latest')"
fi

# Save ECR URI to config
grep -q "^ECR_URI=" "$CONF_FILE" && \
  sed -i "s|^ECR_URI=.*|ECR_URI=\"${ECR_URI}\"|" "$CONF_FILE" || \
  echo "ECR_URI=\"${ECR_URI}\"" >> "$CONF_FILE"

# ── 2. Lifecycle policy ───────────────────────
log_step "2/3 — Applying lifecycle policy..."

LIFECYCLE_POLICY=$(cat "${ECR_DIR}/lifecycle-policy.json")
aws ecr put-lifecycle-policy $R \
  --repository-name "${ECR_REPO_NAME}" \
  --lifecycle-policy-text "${LIFECYCLE_POLICY}"

log_success "Lifecycle policy applied."
log_info "  Rule 1: keep last ${ECR_MAX_IMAGES} tagged images (prefix: sha-)"
log_info "  Rule 2: delete untagged images after 1 day"
log_info "  Why this matters: each deploy creates a new image — without"
log_info "  a lifecycle policy the repo grows unbounded and incurs storage costs"

# ── 3. Show push commands ─────────────────────
log_step "3/3 — ECR authentication reference..."

log_info ""
log_info "Manual push commands (for reference — GitHub Actions does this automatically):"
echo ""
echo -e "  ${CYAN}# Authenticate Docker to ECR${NC}"
echo -e "  aws ecr get-login-password --region ${AWS_REGION} | \\"
echo -e "    docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo ""
echo -e "  ${CYAN}# Build and tag${NC}"
echo -e "  docker build -t ${ECR_REPO_NAME} ./app"
echo -e "  docker tag ${ECR_REPO_NAME}:latest ${ECR_URI}:latest"
echo ""
echo -e "  ${CYAN}# Push${NC}"
echo -e "  docker push ${ECR_URI}:latest"
echo ""

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  03 — ECR setup completed                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "Repository  : ${ECR_REPO_NAME}"
log_success "URI         : ${ECR_URI}"
log_success "Scan on push: enabled"
log_success "Lifecycle   : max ${ECR_MAX_IMAGES} images, untagged expire in 1 day"
echo ""
echo -e "${CYAN}${BOLD}── How to verify in the AWS Console ────────────────${NC}"
echo ""
echo -e "  ${BOLD}1. Repository${NC}"
echo -e "     ECR → Repositories → '${ECR_REPO_NAME}'"
echo -e "     ${YELLOW}→ URI: ${ECR_URI}${NC}"
echo -e "     ${YELLOW}→ Images: empty for now — GitHub Actions will push here${NC}"
echo ""
echo -e "  ${BOLD}2. Scan on push${NC}"
echo -e "     ECR → '${ECR_REPO_NAME}' → Edit → Image scan settings"
echo -e "     ${YELLOW}→ Scan on push: enabled${NC}"
echo -e "     ${YELLOW}→ After first push: Images tab shows CVE findings per image${NC}"
echo ""
echo -e "  ${BOLD}3. Lifecycle policy${NC}"
echo -e "     ECR → '${ECR_REPO_NAME}' → Lifecycle policies"
echo -e "     ${YELLOW}→ 2 rules listed: tagged limit + untagged expiry${NC}"
echo ""
echo -e "  ${BOLD}4. Pricing note${NC}"
echo -e "     ${YELLOW}→ First 500 MB/month free · then \$0.10/GB${NC}"
echo -e "     ${YELLOW}→ Lifecycle policy prevents unbounded growth${NC}"
echo ""