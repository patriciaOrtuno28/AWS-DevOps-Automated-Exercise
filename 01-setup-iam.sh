#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  01-setup-iam.sh
#  Configura la identidad para el ejercicio DevOps:
#    1. OIDC provider para GitHub Actions
#    2. IAM role que GitHub Actions puede asumir
#    3. Deploy policy (ECR push + ECS deploy)
#    4. ECS execution role (pull images, write logs)
#    5. ECS task role (permisos del contenedor)
#
#  La clave de este paso: GitHub Actions NUNCA
#  almacena AWS_ACCESS_KEY_ID. En su lugar obtiene
#  credenciales temporales via OIDC token.
#
#  JSON templates en: iam/
#
#  Uso:
#    chmod +x 01-setup-iam.sh
#    ./01-setup-iam.sh
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

render_template() {
  local file="$1"; shift
  local content
  content=$(cat "$file")
  while [ $# -ge 2 ]; do
    content="${content//\{\{$1\}\}/$2}"
    shift 2
  done
  echo "$content"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/config.env"
IAM_DIR="${SCRIPT_DIR}/iam"

[ ! -f "$CONF_FILE" ] && log_error "config.env not found"
[ ! -d "$IAM_DIR"   ] && log_error "iam/ directory not found"

for f in github-oidc-trust-policy.json github-deploy-policy.json \
          ecs-execution-trust-policy.json ecs-task-policy.json; do
  [ ! -f "${IAM_DIR}/${f}" ] && log_error "Missing template: iam/${f}"
done

source "$CONF_FILE"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      01 — IAM + OIDC setup               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log_info "Project     : ${PROJECT_NAME}"
log_info "Account     : ${AWS_ACCOUNT_ID}"
log_info "GitHub repo : ${GITHUB_ORG}/${GITHUB_REPO}"
log_info "OIDC role   : ${GITHUB_OIDC_ROLE_NAME}"
log_info "Exec role   : ${ECS_EXECUTION_ROLE_NAME}"
log_info "Task role   : ${ECS_TASK_ROLE_NAME}"

# ── 1. GitHub OIDC provider ───────────────────
log_step "1/5 — Creating GitHub OIDC provider..."

OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

EXISTING_OIDC=$(aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${OIDC_ARN}" \
  --query 'Url' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_OIDC" != "NOT_FOUND" ]; then
  log_warn "OIDC provider already exists."
else
  # GitHub's OIDC thumbprint (stable — this is GitHub's TLS certificate SHA1)
  THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

  aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}"
  log_success "GitHub OIDC provider created."
  log_info "  URL       : ${OIDC_URL}"
  log_info "  Audience  : sts.amazonaws.com"
  log_info "  Thumbprint: ${THUMBPRINT}"
fi

log_info ""
log_info "  How OIDC works:"
log_info "  1. GitHub Actions requests a JWT token from GitHub"
log_info "  2. GitHub Actions calls sts:AssumeRoleWithWebIdentity with the JWT"
log_info "  3. AWS validates the JWT against the OIDC provider"
log_info "  4. AWS issues temporary credentials (15min TTL)"
log_info "  5. No AWS_ACCESS_KEY_ID ever stored in GitHub"

# ── 2. GitHub deploy role ─────────────────────
log_step "2/5 — Creating GitHub Actions deploy role..."

EXISTING_ROLE=$(aws iam get-role \
  --role-name "${GITHUB_OIDC_ROLE_NAME}" \
  --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_ROLE" != "NOT_FOUND" ]; then
  log_warn "Role already exists: ${GITHUB_OIDC_ROLE_NAME}"
else
  TRUST_DOC=$(render_template "${IAM_DIR}/github-oidc-trust-policy.json" \
    AWS_ACCOUNT_ID "${AWS_ACCOUNT_ID}" \
    GITHUB_ORG "${GITHUB_ORG}" \
    GITHUB_REPO "${GITHUB_REPO}")

  aws iam create-role \
    --role-name "${GITHUB_OIDC_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" \
    --description "Assumed by GitHub Actions via OIDC - no stored credentials" \
    --output table
  log_success "Role created: ${GITHUB_OIDC_ROLE_NAME}"
  log_info "  Trust: only repo ${GITHUB_ORG}/${GITHUB_REPO} can assume this role"
fi

# ── 3. Deploy policy ──────────────────────────
log_step "3/5 — Creating and attaching deploy policy..."

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

EXISTING_POLICY=$(aws iam get-policy \
  --policy-arn "${POLICY_ARN}" \
  --query 'Policy.PolicyName' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_POLICY" != "NOT_FOUND" ]; then
  log_warn "Policy already exists: ${IAM_POLICY_NAME}"
else
  POLICY_DOC=$(render_template "${IAM_DIR}/github-deploy-policy.json" \
    AWS_ACCOUNT_ID "${AWS_ACCOUNT_ID}" \
    AWS_REGION "${AWS_REGION}" \
    ECR_REPO_NAME "${ECR_REPO_NAME}" \
    ECS_EXECUTION_ROLE_NAME "${ECS_EXECUTION_ROLE_NAME}" \
    ECS_TASK_ROLE_NAME "${ECS_TASK_ROLE_NAME}")

  POLICY_ARN=$(aws iam create-policy \
    --policy-name "${IAM_POLICY_NAME}" \
    --policy-document "${POLICY_DOC}" \
    --description "GitHub Actions deploy policy - ECR push and ECS update" \
    --query 'Policy.Arn' --output text)
  log_success "Policy created: ${POLICY_ARN}"
  log_info "  Grants: ECR push, ECS register task + update service, IAM PassRole"
fi

aws iam attach-role-policy \
  --role-name "${GITHUB_OIDC_ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}" 2>/dev/null && \
  log_success "Deploy policy attached to GitHub role." || \
  log_warn "Policy already attached."

# ── 4. ECS execution role ─────────────────────
log_step "4/5 — Creating ECS execution role..."

EXISTING_EXEC=$(aws iam get-role \
  --role-name "${ECS_EXECUTION_ROLE_NAME}" \
  --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_EXEC" != "NOT_FOUND" ]; then
  log_warn "Execution role already exists: ${ECS_EXECUTION_ROLE_NAME}"
else
  EXEC_TRUST=$(cat "${IAM_DIR}/ecs-execution-trust-policy.json")
  aws iam create-role \
    --role-name "${ECS_EXECUTION_ROLE_NAME}" \
    --assume-role-policy-document "${EXEC_TRUST}" \
    --description "ECS execution role - pull ECR images and write CloudWatch logs" \
    --output table

  # AWS managed policy covers ECR pull + CloudWatch logs
  aws iam attach-role-policy \
    --role-name "${ECS_EXECUTION_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

  log_success "Execution role created: ${ECS_EXECUTION_ROLE_NAME}"
  log_info "  Attached: AmazonECSTaskExecutionRolePolicy"
  log_info "  Grants  : ECR image pull + CloudWatch log creation"
fi

# ── 5. ECS task role ──────────────────────────
log_step "5/5 — Creating ECS task role..."

EXISTING_TASK=$(aws iam get-role \
  --role-name "${ECS_TASK_ROLE_NAME}" \
  --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_TASK" != "NOT_FOUND" ]; then
  log_warn "Task role already exists: ${ECS_TASK_ROLE_NAME}"
else
  TASK_TRUST=$(cat "${IAM_DIR}/ecs-execution-trust-policy.json")
  aws iam create-role \
    --role-name "${ECS_TASK_ROLE_NAME}" \
    --assume-role-policy-document "${TASK_TRUST}" \
    --description "ECS task role - permissions for the running container" \
    --output table

  TASK_POLICY_DOC=$(render_template "${IAM_DIR}/ecs-task-policy.json" \
    AWS_ACCOUNT_ID "${AWS_ACCOUNT_ID}" \
    AWS_REGION "${AWS_REGION}" \
    LOG_GROUP_NAME "${LOG_GROUP_NAME}" \
    PROJECT_NAME "${PROJECT_NAME}")

  aws iam put-role-policy \
    --role-name "${ECS_TASK_ROLE_NAME}" \
    --policy-name "${PROJECT_NAME}-task-inline" \
    --policy-document "${TASK_POLICY_DOC}"

  log_success "Task role created: ${ECS_TASK_ROLE_NAME}"
  log_info "  Grants: CloudWatch log write + SSM parameter read"
fi

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  01 — IAM + OIDC setup completed         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "OIDC provider  : token.actions.githubusercontent.com"
log_success "GitHub role    : ${GITHUB_OIDC_ROLE_NAME}"
log_success "Deploy policy  : ${IAM_POLICY_NAME}"
log_success "Execution role : ${ECS_EXECUTION_ROLE_NAME}"
log_success "Task role      : ${ECS_TASK_ROLE_NAME}"
echo ""
echo -e "${CYAN}${BOLD}── How to verify in the AWS Console ────────────────${NC}"
echo ""
echo -e "  ${BOLD}1. OIDC provider${NC}"
echo -e "     IAM → Identity providers"
echo -e "     ${YELLOW}→ token.actions.githubusercontent.com listed${NC}"
echo -e "     ${YELLOW}→ Audience: sts.amazonaws.com${NC}"
echo ""
echo -e "  ${BOLD}2. GitHub role${NC}"
echo -e "     IAM → Roles → '${GITHUB_OIDC_ROLE_NAME}'"
echo -e "     ${YELLOW}→ Trust relationships → Federated: token.actions.githubusercontent.com${NC}"
echo -e "     ${YELLOW}→ Condition: sub = repo:${GITHUB_ORG}/${GITHUB_REPO}:*${NC}"
echo ""
echo -e "  ${BOLD}3. Deploy policy${NC}"
echo -e "     IAM → Policies → '${IAM_POLICY_NAME}'"
echo -e "     ${YELLOW}→ Permissions: ECRAuth, ECRPush, ECSDeployRead, ECSDeployWrite, PassRole${NC}"
echo ""
echo -e "  ${BOLD}4. Execution role${NC}"
echo -e "     IAM → Roles → '${ECS_EXECUTION_ROLE_NAME}'"
echo -e "     ${YELLOW}→ Attached: AmazonECSTaskExecutionRolePolicy (AWS managed)${NC}"
echo ""
echo -e "  ${BOLD}5. Key concept — OIDC vs access keys${NC}"
echo -e "     ${YELLOW}→ No AWS_ACCESS_KEY_ID in GitHub Secrets${NC}"
echo -e "     ${YELLOW}→ GitHub token validated by AWS → temp credentials issued${NC}"
echo -e "     ${YELLOW}→ Credentials expire after 15 minutes automatically${NC}"
echo -e "     ${YELLOW}→ Trust is scoped to a specific repo — not all of GitHub${NC}"
echo ""