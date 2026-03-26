#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  06-setup-monitoring.sh
#  Configura observabilidad del cluster ECS:
#    1. SNS topic para alertas
#    2. Alarm CPU alta (>80% por 5 min)
#    3. Alarm memoria alta (>80% por 5 min)
#    4. Alarm unhealthy targets en el ALB
#    5. Alarm deploy failed (running tasks = 0)
#
#  Uso:
#    chmod +x 06-setup-monitoring.sh
#    ./06-setup-monitoring.sh
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
echo -e "${BOLD}║      06 — Monitoring setup               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ── 1. SNS topic ──────────────────────────────
log_step "1/5 — Creating SNS topic..."

SNS_ARN=$(aws sns create-topic $R \
  --name "${SNS_TOPIC_NAME}" \
  --query 'TopicArn' --output text)
log_success "SNS topic: ${SNS_ARN}"

grep -q "^SNS_ARN=" "$CONF_FILE" && \
  sed -i "s|^SNS_ARN=.*|SNS_ARN=\"${SNS_ARN}\"|" "$CONF_FILE" || \
  printf "\nSNS_ARN=\"${SNS_ARN}\"\n" >> "$CONF_FILE"

echo ""
log_info "To receive email alerts, subscribe your email:"
log_info "  aws sns subscribe --region ${AWS_REGION} \\"
log_info "    --topic-arn ${SNS_ARN} \\"
log_info "    --protocol email \\"
log_info "    --notification-endpoint your@email.com"

# ── 2. CPU alarm ──────────────────────────────
log_step "2/5 — Creating CPU alarm..."

EXISTING=$(aws cloudwatch describe-alarms $R \
  --alarm-names "${ALARM_CPU_NAME}" \
  --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING" ]; then
  log_warn "Alarm already exists: ${ALARM_CPU_NAME}"
else
  aws cloudwatch put-metric-alarm $R \
    --alarm-name "${ALARM_CPU_NAME}" \
    --alarm-description "ECS CPU utilization > 80% for 5 minutes" \
    --namespace AWS/ECS \
    --metric-name CPUUtilization \
    --dimensions \
      Name=ClusterName,Value="${ECS_CLUSTER_NAME}" \
      Name=ServiceName,Value="${ECS_SERVICE_NAME}" \
    --statistic Average \
    --period 300 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 1 \
    --alarm-actions "${SNS_ARN}" \
    --treat-missing-data notBreaching
  log_success "CPU alarm created: >= 80% for 5 min → SNS"
fi

# ── 3. Memory alarm ───────────────────────────
log_step "3/5 — Creating memory alarm..."

EXISTING=$(aws cloudwatch describe-alarms $R \
  --alarm-names "${ALARM_MEMORY_NAME}" \
  --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING" ]; then
  log_warn "Alarm already exists: ${ALARM_MEMORY_NAME}"
else
  aws cloudwatch put-metric-alarm $R \
    --alarm-name "${ALARM_MEMORY_NAME}" \
    --alarm-description "ECS memory utilization > 80% for 5 minutes" \
    --namespace AWS/ECS \
    --metric-name MemoryUtilization \
    --dimensions \
      Name=ClusterName,Value="${ECS_CLUSTER_NAME}" \
      Name=ServiceName,Value="${ECS_SERVICE_NAME}" \
    --statistic Average \
    --period 300 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 1 \
    --alarm-actions "${SNS_ARN}" \
    --treat-missing-data notBreaching
  log_success "Memory alarm created: >= 80% for 5 min → SNS"
fi

# ── 4. Unhealthy targets alarm ────────────────
log_step "4/5 — Creating unhealthy targets alarm..."

EXISTING=$(aws cloudwatch describe-alarms $R \
  --alarm-names "${ALARM_HEALTH_NAME}" \
  --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING" ]; then
  log_warn "Alarm already exists: ${ALARM_HEALTH_NAME}"
else
  TG_SUFFIX=$(echo "${TG_ARN}" | awk -F':' '{print $NF}' | sed 's|targetgroup/||')
  ALB_SUFFIX=$(echo "${ALB_ARN}" | awk -F':' '{print $NF}' | sed 's|loadbalancer/||')

  aws cloudwatch put-metric-alarm $R \
    --alarm-name "${ALARM_HEALTH_NAME}" \
    --alarm-description "ALB has unhealthy ECS targets" \
    --namespace AWS/ApplicationELB \
    --metric-name UnHealthyHostCount \
    --dimensions \
      Name=TargetGroup,Value="targetgroup/${TG_SUFFIX}" \
      Name=LoadBalancer,Value="${ALB_SUFFIX}" \
    --statistic Maximum \
    --period 60 \
    --threshold 0 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --alarm-actions "${SNS_ARN}" \
    --treat-missing-data notBreaching
  log_success "Unhealthy targets alarm created: > 0 for 2 min → SNS"
fi

# ── 5. Running tasks = 0 alarm ────────────────
log_step "5/5 — Creating zero running tasks alarm..."

ALARM_ZERO_TASKS="${PROJECT_NAME}-zero-running-tasks"

EXISTING=$(aws cloudwatch describe-alarms $R \
  --alarm-names "${ALARM_ZERO_TASKS}" \
  --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING" ]; then
  log_warn "Alarm already exists: ${ALARM_ZERO_TASKS}"
else
  aws cloudwatch put-metric-alarm $R \
    --alarm-name "${ALARM_ZERO_TASKS}" \
    --alarm-description "ECS service has 0 running tasks — service is down" \
    --namespace ECS/ContainerInsights \
    --metric-name RunningTaskCount \
    --dimensions \
      Name=ClusterName,Value="${ECS_CLUSTER_NAME}" \
      Name=ServiceName,Value="${ECS_SERVICE_NAME}" \
    --statistic Average \
    --period 60 \
    --threshold 1 \
    --comparison-operator LessThanThreshold \
    --evaluation-periods 1 \
    --alarm-actions "${SNS_ARN}" \
    --treat-missing-data breaching
  log_success "Zero tasks alarm created: running tasks < 1 → SNS"
fi

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  06 — Monitoring setup completed         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "SNS topic : ${SNS_TOPIC_NAME}"
log_success "Alarms    : CPU · memory · unhealthy targets · zero tasks"
echo ""
echo -e "${CYAN}${BOLD}── How to verify ───────────────────────────────────${NC}"
echo ""
echo -e "  CloudWatch → Alarms → filter '${PROJECT_NAME}'"
echo -e "  ${YELLOW}→ 4 alarms in OK state${NC}"
echo -e "  ECS → Clusters → '${ECS_CLUSTER_NAME}' → Monitoring tab"
echo -e "  ${YELLOW}→ Container Insights graphs: CPU, memory, task count${NC}"
echo ""
