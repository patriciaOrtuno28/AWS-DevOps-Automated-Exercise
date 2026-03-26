#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  04-setup-ecs.sh
#  Crea la capa de computo con ECS Fargate:
#    1. CloudWatch log group
#    2. ALB + target group + listener
#    3. ECS cluster
#    4. Task definition
#    5. ECS service (2 tasks, rolling update)
#
#  Con Fargate no hay servidores que gestionar.
#  Defines CPU/memoria en la task definition
#  y AWS decide donde ejecutar los contenedores.
#
#  JSON templates en: ecs/
#
#  Uso:
#    chmod +x 04-setup-ecs.sh
#    ./04-setup-ecs.sh
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
ECS_DIR="${SCRIPT_DIR}/ecs"

[ ! -f "$CONF_FILE" ] && log_error "config.env not found"
[ ! -d "$ECS_DIR"   ] && log_error "ecs/ directory not found"
[ ! -f "${ECS_DIR}/task-definition.json" ] && \
  log_error "Missing template: ecs/task-definition.json"

source "$CONF_FILE"
R="--region ${AWS_REGION}"

# Validate required IDs from previous steps
[ -z "${VPC_ID:-}"             ] && log_error "VPC_ID not set — run 02-setup-network.sh first"
[ -z "${SUBNET_PUBLIC_1_ID:-}" ] && log_error "SUBNET_PUBLIC_1_ID not set — run 02-setup-network.sh first"
[ -z "${SUBNET_PUBLIC_2_ID:-}" ] && log_error "SUBNET_PUBLIC_2_ID not set — run 02-setup-network.sh first"
[ -z "${SG_ALB_ID:-}"          ] && log_error "SG_ALB_ID not set — run 02-setup-network.sh first"
[ -z "${SG_ECS_ID:-}"          ] && log_error "SG_ECS_ID not set — run 02-setup-network.sh first"
[ -z "${ECR_URI:-}"            ] && log_error "ECR_URI not set — run 03-setup-ecr.sh first"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      04 — ECS Fargate setup              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log_info "Cluster     : ${ECS_CLUSTER_NAME}"
log_info "Service     : ${ECS_SERVICE_NAME}"
log_info "Task family : ${ECS_TASK_FAMILY}"
log_info "CPU / Memory: ${ECS_CPU} / ${ECS_MEMORY}"
log_info "Desired     : ${ECS_DESIRED_COUNT} tasks"
log_info "Image       : ${ECR_URI}:latest"

# ── 1. CloudWatch log group ───────────────────
log_step "1/5 — Creating CloudWatch log group..."

# Store log group name in variable — Git Bash converts /ecs/... to a Windows path
ECS_LOG_GROUP="/ecs/devops-exercise"
aws logs create-log-group $R \
  --log-group-name "${ECS_LOG_GROUP}" 2>/dev/null && \
  log_success "Log group created: ${ECS_LOG_GROUP}" || \
  log_warn "Log group already exists."

aws logs put-retention-policy $R \
  --log-group-name "${ECS_LOG_GROUP}" \
  --retention-in-days 14 2>/dev/null || true
log_info "  Retention: 14 days"
LOG_GROUP_NAME_VAR="${ECS_LOG_GROUP}"

# ── 2. ALB + Target Group + Listener ─────────
log_step "2/5 — Creating ALB..."

EXISTING_ALB=$(aws elbv2 describe-load-balancers $R \
  --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_ALB" ]; then
  ALB_ARN="$EXISTING_ALB"
  ALB_DNS=$(aws elbv2 describe-load-balancers $R \
    --load-balancer-arns "${ALB_ARN}" \
    --query 'LoadBalancers[0].DNSName' --output text)
  log_warn "ALB already exists: ${ALB_DNS}"
else
  ALB_ARN=$(aws elbv2 create-load-balancer $R \
    --name "${ALB_NAME}" \
    --subnets "${SUBNET_PUBLIC_1_ID}" "${SUBNET_PUBLIC_2_ID}" \
    --security-groups "${SG_ALB_ID}" \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
  ALB_DNS=$(aws elbv2 describe-load-balancers $R \
    --load-balancer-arns "${ALB_ARN}" \
    --query 'LoadBalancers[0].DNSName' --output text)
  log_success "ALB created: ${ALB_DNS}"
fi

grep -q "^ALB_ARN=" "$CONF_FILE" && \
  sed -i "s|^ALB_ARN=.*|ALB_ARN=\"${ALB_ARN}\"|" "$CONF_FILE" || \
  echo "ALB_ARN=\"${ALB_ARN}\"" >> "$CONF_FILE"
grep -q "^ALB_DNS=" "$CONF_FILE" && \
  sed -i "s|^ALB_DNS=.*|ALB_DNS=\"${ALB_DNS}\"|" "$CONF_FILE" || \
  echo "ALB_DNS=\"${ALB_DNS}\"" >> "$CONF_FILE"

# Target group
EXISTING_TG=$(aws elbv2 describe-target-groups $R \
  --names "${TARGET_GROUP_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_TG" ]; then
  TG_ARN="$EXISTING_TG"
  log_warn "Target group already exists: ${TG_ARN}"
else
  # Store path in variable — Git Bash converts literal /health to a Windows path
  HC_PATH="/health"
  TG_ARN=$(aws elbv2 create-target-group $R \
    --name "${TARGET_GROUP_NAME}" \
    --protocol HTTP \
    --port "${APP_PORT}" \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path "${HC_PATH}" \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
  log_success "Target group created: ${TG_ARN}"
  log_info "  Target type: ip (required for Fargate — no EC2 instance IDs)"
  log_info "  Health check: GET /health every 30s"
fi

grep -q "^TG_ARN=" "$CONF_FILE" && \
  sed -i "s|^TG_ARN=.*|TG_ARN=\"${TG_ARN}\"|" "$CONF_FILE" || \
  echo "TG_ARN=\"${TG_ARN}\"" >> "$CONF_FILE"

# HTTP listener
EXISTING_LISTENER=$(aws elbv2 describe-listeners $R \
  --load-balancer-arn "${ALB_ARN}" \
  --query 'Listeners[0].ListenerArn' \
  --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_LISTENER" ]; then
  log_warn "Listener already exists."
else
  aws elbv2 create-listener $R \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}"
  log_success "HTTP listener created: port 80 → target group"
fi

# ── 3. ECS cluster ────────────────────────────
log_step "3/5 — Creating ECS cluster..."

EXISTING_CLUSTER=$(aws ecs describe-clusters $R \
  --clusters "${ECS_CLUSTER_NAME}" \
  --query 'clusters[0].status' \
  --output text 2>/dev/null | grep -v "None" || echo "NOT_FOUND")

if [ "$EXISTING_CLUSTER" = "ACTIVE" ]; then
  log_warn "Cluster already exists: ${ECS_CLUSTER_NAME}"
else
  aws ecs create-cluster $R \
    --cluster-name "${ECS_CLUSTER_NAME}" \
    --settings name=containerInsights,value=enabled \
    --output table
  log_success "ECS cluster created: ${ECS_CLUSTER_NAME}"
  log_info "  Container Insights: enabled (CPU, memory, network metrics)"
fi

# ── 4. Task definition ────────────────────────
log_step "4/5 — Registering task definition..."

TASK_DEF_DOC=$(render_template "${ECS_DIR}/task-definition.json" \
  ECS_TASK_FAMILY "${ECS_TASK_FAMILY}" \
  ECS_CPU "${ECS_CPU}" \
  ECS_MEMORY "${ECS_MEMORY}" \
  AWS_ACCOUNT_ID "${AWS_ACCOUNT_ID}" \
  AWS_REGION "${AWS_REGION}" \
  ECS_EXECUTION_ROLE_NAME "${ECS_EXECUTION_ROLE_NAME}" \
  ECS_TASK_ROLE_NAME "${ECS_TASK_ROLE_NAME}" \
  APP_NAME "${APP_NAME}" \
  ECR_URI "${ECR_URI}" \
  APP_PORT "${APP_PORT}" \
  APP_VERSION "${APP_VERSION}" \
  LOG_GROUP_NAME "${LOG_GROUP_NAME_VAR}")

TASK_DEF_ARN=$(aws ecs register-task-definition $R \
  --cli-input-json "${TASK_DEF_DOC}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

log_success "Task definition registered: ${TASK_DEF_ARN}"
log_info "  Image   : ${ECR_URI}:latest"
log_info "  CPU     : ${ECS_CPU} units (1 vCPU = 1024)"
log_info "  Memory  : ${ECS_MEMORY} MB"
log_info "  Port    : ${APP_PORT}"
log_info "  Logs    : ${LOG_GROUP_NAME_VAR}"

grep -q "^TASK_DEF_ARN=" "$CONF_FILE" && \
  sed -i "s|^TASK_DEF_ARN=.*|TASK_DEF_ARN=\"${TASK_DEF_ARN}\"|" "$CONF_FILE" || \
  echo "TASK_DEF_ARN=\"${TASK_DEF_ARN}\"" >> "$CONF_FILE"

# ── 5. ECS service ────────────────────────────
log_step "5/5 — Creating ECS service..."

EXISTING_SERVICE=$(aws ecs describe-services $R \
  --cluster "${ECS_CLUSTER_NAME}" \
  --services "${ECS_SERVICE_NAME}" \
  --query 'services[0].status' \
  --output text 2>/dev/null | grep -v "None" || echo "NOT_FOUND")

if [ "$EXISTING_SERVICE" = "ACTIVE" ]; then
  log_warn "Service already exists: ${ECS_SERVICE_NAME}"
else
  aws ecs create-service $R \
    --cluster "${ECS_CLUSTER_NAME}" \
    --service-name "${ECS_SERVICE_NAME}" \
    --task-definition "${ECS_TASK_FAMILY}" \
    --desired-count "${ECS_DESIRED_COUNT}" \
    --launch-type FARGATE \
    --network-configuration \
      "awsvpcConfiguration={subnets=[${SUBNET_PUBLIC_1_ID},${SUBNET_PUBLIC_2_ID}],securityGroups=[${SG_ECS_ID}],assignPublicIp=ENABLED}" \
    --load-balancers \
      "targetGroupArn=${TG_ARN},containerName=${APP_NAME},containerPort=${APP_PORT}" \
    --deployment-configuration \
      "minimumHealthyPercent=50,maximumPercent=200" \
    --deployment-controller type=ECS \
    --output table

  log_success "ECS service created: ${ECS_SERVICE_NAME}"
  log_info "  Desired tasks    : ${ECS_DESIRED_COUNT}"
  log_info "  Launch type      : FARGATE"
  log_info "  Rolling update   : min 50% healthy, max 200%"
  log_info "  Subnets          : ${SUBNET_PUBLIC_1_ID} + ${SUBNET_PUBLIC_2_ID}"
  log_info ""
  log_info "  Rolling update explained:"
  log_info "  - On deploy: launch new task (200% = 4 tasks temporarily)"
  log_info "  - Wait for new task health check to pass"
  log_info "  - Drain and stop old task"
  log_info "  - Repeat until all tasks are updated"
  log_info "  - Zero downtime — ALB always has healthy targets"
fi

# ── Wait for service to stabilise ─────────────
echo ""
log_info "Waiting for service to reach steady state (first deploy takes ~2 min)..."
log_info "The service will fail to start until GitHub Actions pushes the first image."
log_info "This is expected — continue to step 05 to set up the pipeline."

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  04 — ECS Fargate setup completed        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "ALB         : http://${ALB_DNS}"
log_success "Cluster     : ${ECS_CLUSTER_NAME}"
log_success "Service     : ${ECS_SERVICE_NAME}"
log_success "Task def    : ${TASK_DEF_ARN}"
log_success "Log group   : ${LOG_GROUP_NAME_VAR}"
echo ""
echo -e "${CYAN}${BOLD}── How to verify in the AWS Console ────────────────${NC}"
echo ""
echo -e "  ${BOLD}1. ECS cluster${NC}"
echo -e "     ECS → Clusters → '${ECS_CLUSTER_NAME}'"
echo -e "     ${YELLOW}→ Services: 1 · Container Insights: enabled${NC}"
echo ""
echo -e "  ${BOLD}2. ECS service${NC}"
echo -e "     ECS → Clusters → '${ECS_CLUSTER_NAME}' → Services → '${ECS_SERVICE_NAME}'"
echo -e "     ${YELLOW}→ Desired: ${ECS_DESIRED_COUNT} · Running: 0 (no image yet — normal)${NC}"
echo -e "     ${YELLOW}→ Deployments tab: shows rolling update history${NC}"
echo ""
echo -e "  ${BOLD}3. Task definition${NC}"
echo -e "     ECS → Task definitions → '${ECS_TASK_FAMILY}'"
echo -e "     ${YELLOW}→ Revision 1 · FARGATE · ${ECS_CPU} CPU · ${ECS_MEMORY} MB${NC}"
echo -e "     ${YELLOW}→ Container: ${APP_NAME} · port ${APP_PORT} · awslogs driver${NC}"
echo ""
echo -e "  ${BOLD}4. ALB${NC}"
echo -e "     EC2 → Load Balancers → '${ALB_NAME}'"
echo -e "     ${YELLOW}→ State: Active · DNS: ${ALB_DNS}${NC}"
echo -e "     ${YELLOW}→ Target group: unhealthy until first image is pushed${NC}"
echo ""
echo -e "  ${BOLD}5. Fargate vs EC2 — exam tip${NC}"
echo -e "     ${YELLOW}→ Fargate: serverless containers — no EC2 to manage or patch${NC}"
echo -e "     ${YELLOW}→ EC2 launch type: you manage the underlying instances${NC}"
echo -e "     ${YELLOW}→ Fargate is more expensive per task but zero ops overhead${NC}"
echo -e "     ${YELLOW}→ Target type must be 'ip' for Fargate (not 'instance')${NC}"
echo ""