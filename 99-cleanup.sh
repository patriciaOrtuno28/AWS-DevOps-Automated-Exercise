#!/bin/bash

# ─────────────────────────────────────────────
#  99-cleanup.sh
#  Elimina todos los recursos AWS del ejercicio
#  y restaura config.env a su estado original.
#
#  Orden de borrado (dependencias primero):
#    1.  ECS service + cluster
#    2.  ALB + target group + listener
#    3.  CloudWatch alarms + log group
#    4.  SNS topic
#    5.  ECR repository (todas las imagenes)
#    6.  IAM roles + policies
#       (OIDC provider NO se borra — es compartido)
#    7.  VPC + subnets + SG + IGW + RTB
#    8.  Restaurar config.env
#    9.  Restaurar task-definition.json
#
#  Uso:
#    chmod +x 99-cleanup.sh
#    ./99-cleanup.sh
# ─────────────────────────────────────────────

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[SKIP]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}> $1${NC}"; }
log_fail()    { echo -e "${RED}[FAIL]${NC} $1 — continuing..."; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/config.env"
[ ! -f "$CONF_FILE" ] && { echo "config.env not found"; exit 1; }
source "$CONF_FILE"
R="--region ${AWS_REGION}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      99 — Full cleanup                   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}  Deletes ALL AWS resources created by this exercise.${NC}"
echo -e "${RED}  The GitHub OIDC provider is preserved (shared resource).${NC}"
echo ""
read -p "$(echo -e "${YELLOW}[INPUT]${NC} Type 'borrar' to confirm: ")" CONFIRM
[ "$CONFIRM" != "borrar" ] && { log_info "Cancelled."; exit 0; }

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

# ── 1. ECS service + cluster ──────────────────
log_step "1/9 — Deleting ECS service and cluster..."

aws ecs update-service $R \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service "${ECS_SERVICE_NAME}" \
  --desired-count 0 2>/dev/null && \
  log_success "Service scaled to 0." || log_warn "Service not found."

sleep 10

aws ecs delete-service $R \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service "${ECS_SERVICE_NAME}" \
  --force 2>/dev/null && \
  log_success "ECS service deleted." || log_warn "Service not found."

# Deregister all task definition revisions
TASK_REVISIONS=$(aws ecs list-task-definitions $R \
  --family-prefix "${ECS_TASK_FAMILY}" \
  --query 'taskDefinitionArns[*]' \
  --output text 2>/dev/null || echo "")

for TD in $TASK_REVISIONS; do
  aws ecs deregister-task-definition $R \
    --task-definition "${TD}" 2>/dev/null && \
    log_success "Task definition deregistered: ${TD}" || true
done

aws ecs delete-cluster $R \
  --cluster "${ECS_CLUSTER_NAME}" 2>/dev/null && \
  log_success "ECS cluster deleted." || log_warn "Cluster not found."

# ── 2. ALB + Target group ─────────────────────
log_step "2/9 — Deleting ALB and target group..."

LISTENER_ARN=$(aws elbv2 describe-listeners $R \
  --load-balancer-arn "${ALB_ARN:-none}" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null | grep -v "None" || echo "")
[ -n "$LISTENER_ARN" ] && \
  aws elbv2 delete-listener $R \
    --listener-arn "${LISTENER_ARN}" 2>/dev/null && \
  log_success "Listener deleted." || true

[ -n "${ALB_ARN:-}" ] && \
  aws elbv2 delete-load-balancer $R \
    --load-balancer-arn "${ALB_ARN}" 2>/dev/null && \
  log_success "ALB deleted." || log_warn "ALB not found."

log_info "Waiting 30s for ALB to be deleted..."
sleep 30

[ -n "${TG_ARN:-}" ] && \
  aws elbv2 delete-target-group $R \
    --target-group-arn "${TG_ARN}" 2>/dev/null && \
  log_success "Target group deleted." || log_warn "Target group not found."

# ── 3. CloudWatch alarms + log group ──────────
log_step "3/9 — Deleting CloudWatch alarms and log group..."

for ALARM in \
  "${ALARM_CPU_NAME}" \
  "${ALARM_MEMORY_NAME}" \
  "${ALARM_HEALTH_NAME}" \
  "${PROJECT_NAME}-zero-running-tasks"; do
  [ -z "$ALARM" ] && continue
  aws cloudwatch delete-alarms $R \
    --alarm-names "${ALARM}" 2>/dev/null && \
    log_success "Alarm deleted: ${ALARM}" || \
    log_warn "Alarm not found: ${ALARM}"
done

LOG_GROUP_VAR="${LOG_GROUP_NAME}"
aws logs delete-log-group $R \
  --log-group-name "${LOG_GROUP_VAR}" 2>/dev/null && \
  log_success "Log group deleted: ${LOG_GROUP_VAR}" || \
  log_warn "Log group not found."

# ── 4. SNS topic ──────────────────────────────
log_step "4/9 — Deleting SNS topic..."

[ -n "${SNS_ARN:-}" ] && \
  aws sns delete-topic $R \
    --topic-arn "${SNS_ARN}" 2>/dev/null && \
  log_success "SNS topic deleted." || log_warn "SNS topic not found."

# ── 5. ECR repository ─────────────────────────
log_step "5/9 — Deleting ECR repository and all images..."

aws ecr delete-repository $R \
  --repository-name "${ECR_REPO_NAME}" \
  --force 2>/dev/null && \
  log_success "ECR repository deleted (all images removed)." || \
  log_warn "ECR repository not found."

# ── 6. IAM roles + policies ───────────────────
log_step "6/9 — Deleting IAM roles and policies..."

# NOTE: OIDC provider is intentionally NOT deleted — it is shared with other projects.
log_info "Skipping OIDC provider deletion (shared resource — used by other projects)."

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

# GitHub role
aws iam detach-role-policy \
  --role-name "${GITHUB_OIDC_ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}" 2>/dev/null || true
aws iam delete-role \
  --role-name "${GITHUB_OIDC_ROLE_NAME}" 2>/dev/null && \
  log_success "GitHub role deleted." || log_warn "GitHub role not found."

# Deploy policy
aws iam delete-policy \
  --policy-arn "${POLICY_ARN}" 2>/dev/null && \
  log_success "Deploy policy deleted." || log_warn "Deploy policy not found."

# ECS execution role
aws iam detach-role-policy \
  --role-name "${ECS_EXECUTION_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
  2>/dev/null || true
aws iam delete-role \
  --role-name "${ECS_EXECUTION_ROLE_NAME}" 2>/dev/null && \
  log_success "ECS execution role deleted." || log_warn "Execution role not found."

# ECS task role
aws iam delete-role-policy \
  --role-name "${ECS_TASK_ROLE_NAME}" \
  --policy-name "${PROJECT_NAME}-task-inline" 2>/dev/null || true
aws iam delete-role \
  --role-name "${ECS_TASK_ROLE_NAME}" 2>/dev/null && \
  log_success "ECS task role deleted." || log_warn "Task role not found."

# ── 7. VPC + networking ───────────────────────
log_step "7/9 — Deleting VPC and networking resources..."

# Security groups
for SG in "${SG_ECS_ID:-}" "${SG_ALB_ID:-}"; do
  [ -z "$SG" ] && continue
  aws ec2 delete-security-group $R \
    --group-id "${SG}" 2>/dev/null && \
    log_success "Security group deleted: ${SG}" || \
    log_warn "SG not found: ${SG}"
done

# Subnets
for SUBNET in "${SUBNET_PUBLIC_1_ID:-}" "${SUBNET_PUBLIC_2_ID:-}"; do
  [ -z "$SUBNET" ] && continue
  aws ec2 delete-subnet $R \
    --subnet-id "${SUBNET}" 2>/dev/null && \
    log_success "Subnet deleted: ${SUBNET}" || \
    log_warn "Subnet not found: ${SUBNET}"
done

# Internet gateway
IGW_ID=$(aws ec2 describe-internet-gateways $R \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID:-none}" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text 2>/dev/null | grep -v "None" || echo "")
if [ -n "$IGW_ID" ]; then
  aws ec2 detach-internet-gateway $R \
    --internet-gateway-id "${IGW_ID}" \
    --vpc-id "${VPC_ID}" 2>/dev/null || true
  aws ec2 delete-internet-gateway $R \
    --internet-gateway-id "${IGW_ID}" 2>/dev/null && \
    log_success "IGW deleted." || log_warn "IGW not found."
fi

# Route tables (non-main)
RTB_IDS=$(aws ec2 describe-route-tables $R \
  --filters "Name=vpc-id,Values=${VPC_ID:-none}" \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
  --output text 2>/dev/null || echo "")
for RTB in $RTB_IDS; do
  aws ec2 delete-route-table $R \
    --route-table-id "${RTB}" 2>/dev/null && \
    log_success "Route table deleted: ${RTB}" || true
done

# VPC
[ -n "${VPC_ID:-}" ] && \
  aws ec2 delete-vpc $R \
    --vpc-id "${VPC_ID}" 2>/dev/null && \
  log_success "VPC deleted: ${VPC_ID}" || \
  log_warn "VPC not found."

# ── 8. Restore config.env ─────────────────────
log_step "8/9 — Restoring config.env..."

cat > "${CONF_FILE}" << 'CONFIG'
# ─────────────────────────────────────────────
#  config.env — AWS DevOps Automated Exercise
#  Generated IDs are removed after cleanup.
# ─────────────────────────────────────────────

# ── AWS ───────────────────────────────────────
AWS_REGION="eu-west-1"

# ── Project ───────────────────────────────────
PROJECT_NAME="devops-exercise"
APP_NAME="devops-app"
APP_PORT="3000"

# ── IAM ───────────────────────────────────────
GITHUB_OIDC_ROLE_NAME="devops-exercise-github-role"
ECS_TASK_ROLE_NAME="devops-exercise-ecs-task-role"
ECS_EXECUTION_ROLE_NAME="devops-exercise-ecs-execution-role"
IAM_POLICY_NAME="devops-exercise-deploy-policy"

# ── GitHub ────────────────────────────────────
GITHUB_ORG=""
GITHUB_REPO=""

# ── Network ───────────────────────────────────
VPC_NAME="devops-exercise-vpc"
VPC_CIDR="10.1.0.0/16"
SUBNET_PUBLIC_1_CIDR="10.1.1.0/24"
SUBNET_PUBLIC_2_CIDR="10.1.2.0/24"
AZ_1="eu-west-1a"
AZ_2="eu-west-1b"
SG_ALB_NAME="devops-exercise-alb-sg"
SG_ECS_NAME="devops-exercise-ecs-sg"

# ── ECR ───────────────────────────────────────
ECR_REPO_NAME="devops-exercise-app"
ECR_SCAN_ON_PUSH="true"
ECR_MAX_IMAGES=10

# ── ECS ───────────────────────────────────────
ECS_CLUSTER_NAME="devops-exercise-cluster"
ECS_SERVICE_NAME="devops-exercise-service"
ECS_TASK_FAMILY="devops-exercise-task"
ECS_CPU="256"
ECS_MEMORY="512"
ECS_DESIRED_COUNT="2"
ALB_NAME="devops-exercise-alb"
TARGET_GROUP_NAME="devops-exercise-tg"
LOG_GROUP_NAME="/ecs/devops-exercise"

# ── Monitoring ────────────────────────────────
ALARM_CPU_NAME="devops-exercise-cpu-high"
ALARM_MEMORY_NAME="devops-exercise-memory-high"
ALARM_HEALTH_NAME="devops-exercise-unhealthy-targets"
SNS_TOPIC_NAME="devops-exercise-alerts"

# ── App ───────────────────────────────────────
APP_VERSION="1.0.0"
CONFIG

log_success "config.env restored (all generated IDs removed)."

# ── 9. Restore task-definition.json ──────────
log_step "9/9 — Restoring ecs/task-definition.json..."

cat > "${SCRIPT_DIR}/ecs/task-definition.json" << 'EOF'
{
  "family": "{{ECS_TASK_FAMILY}}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "{{ECS_CPU}}",
  "memory": "{{ECS_MEMORY}}",
  "executionRoleArn": "arn:aws:iam::{{AWS_ACCOUNT_ID}}:role/{{ECS_EXECUTION_ROLE_NAME}}",
  "taskRoleArn": "arn:aws:iam::{{AWS_ACCOUNT_ID}}:role/{{ECS_TASK_ROLE_NAME}}",
  "containerDefinitions": [
    {
      "name": "{{APP_NAME}}",
      "image": "{{ECR_URI}}:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": {{APP_PORT}},
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "PORT", "value": "{{APP_PORT}}" },
        { "name": "APP_VERSION", "value": "{{APP_VERSION}}" },
        { "name": "NODE_ENV", "value": "production" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "{{LOG_GROUP_NAME}}",
          "awslogs-region": "{{AWS_REGION}}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:{{APP_PORT}}/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF

log_success "ecs/task-definition.json restored to placeholder state."

# Restore app/package.json version to match config.env reset (1.0.0)
sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"1.0.0\"/" \
  "${SCRIPT_DIR}/app/package.json"
log_success "app/package.json version restored to 1.0.0."

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  99 — Cleanup completed                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "All AWS resources deleted."
log_success "config.env restored."
log_success "ecs/task-definition.json restored."
log_info  "OIDC provider preserved (shared with other projects)."
echo ""
log_info "Verify nothing remains:"
log_info "  ECS  → https://eu-west-1.console.aws.amazon.com/ecs"
log_info "  ECR  → https://eu-west-1.console.aws.amazon.com/ecr"
log_info "  VPC  → https://eu-west-1.console.aws.amazon.com/vpc"
log_info "  IAM  → https://console.aws.amazon.com/iam"
echo ""
