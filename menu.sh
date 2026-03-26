#!/bin/bash

# ─────────────────────────────────────────────
#  menu.sh — AWS DevOps Automated Exercise
# ─────────────────────────────────────────────

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; GRAY='\033[0;90m'
BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/config.env"

run_script() {
  local script="${SCRIPT_DIR}/$1"
  [ ! -f "$script" ] && {
    echo -e "\n  ${RED}[ERROR]${NC} Not found: $1"
    read -p "  Press Enter..." _; return; }
  echo ""; bash "$script"; echo ""
  read -p "$(echo -e "  ${GRAY}Press Enter to return...${NC}")" _
}

print_header() {
  clear
  source "$CONF_FILE" 2>/dev/null
  echo ""
  echo -e "${CYAN}${BOLD}  ╔═════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}  ║      AWS DevOps Automated Exercise              ║${NC}"
  echo -e "${CYAN}${BOLD}  ╚═════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${GRAY}GitHub :${NC} ${GITHUB_ORG:-${RED}not set${NC}}/${GITHUB_REPO:-${RED}not set${NC}}"
  echo -e "  ${GRAY}Region :${NC} ${AWS_REGION}   ${GRAY}Version :${NC} ${APP_VERSION:-?}"
  echo ""

  # Fetch AWS status in parallel to temp files
  TMP_ECS=$(mktemp); TMP_ECR=$(mktemp)
  aws ecs describe-services \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].runningCount' \
    --output text >"$TMP_ECS" 2>/dev/null &
  PID_ECS=$!
  aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO_NAME}" \
    --query 'length(imageDetails)' \
    --output text >"$TMP_ECR" 2>/dev/null &
  PID_ECR=$!

  # Spinner while both calls are running
  FRAMES=('|' '/' '-' '\')
  i=0
  while kill -0 $PID_ECS 2>/dev/null || kill -0 $PID_ECR 2>/dev/null; do
    printf "\r  ${GRAY}${FRAMES[$i]} Fetching status...${NC}"
    i=$(( (i+1) % 4 ))
    sleep 0.12
  done
  printf "\r\033[K"  # clear spinner line

  wait $PID_ECS 2>/dev/null; wait $PID_ECR 2>/dev/null
  ECS_STATUS=$(cat "$TMP_ECS" 2>/dev/null || echo "?")
  ECR_IMAGES=$(cat "$TMP_ECR" 2>/dev/null || echo "0")
  rm -f "$TMP_ECS" "$TMP_ECR"

  echo -e "  ${GRAY}ECS    :${NC} $([ "$ECS_STATUS" -ge 1 ] 2>/dev/null && \
    echo -e "${GREEN}● ${ECS_STATUS} tasks running${NC}" || \
    echo -e "${GRAY}○ ${ECS_STATUS} tasks${NC}")"
  echo -e "  ${GRAY}ECR    :${NC} $([ "${ECR_IMAGES:-0}" -gt 0 ] 2>/dev/null && \
    echo -e "${GREEN}● ${ECR_IMAGES} images${NC}" || \
    echo -e "${GRAY}○ no images${NC}")"
  echo -e "  ${GRAY}ALB    :${NC} $([ -n "${ALB_DNS:-}" ] && \
    echo -e "${GREEN}● ${ALB_DNS}${NC}" || \
    echo -e "${GRAY}○ not created${NC}")"
  echo ""
  echo -e "  ${GRAY}─────────────────────────────────────────────────${NC}"
  echo ""
}

configure_github() {
  print_header
  echo -e "  ${BOLD}${CYAN}[ GITHUB CONFIGURATION ]${NC}"
  echo ""
  echo -e "  Current values:"
  echo -e "  ${GRAY}GITHUB_ORG  :${NC} ${GITHUB_ORG:-${RED}(not set)${NC}}"
  echo -e "  ${GRAY}GITHUB_REPO :${NC} ${GITHUB_REPO:-${RED}(not set)${NC}}"
  echo ""

  read -p "$(echo -e "  ${BOLD}GitHub username / org${NC} [${GITHUB_ORG:-empty}]: ")" NEW_ORG
  read -p "$(echo -e "  ${BOLD}Repository name${NC}       [${GITHUB_REPO:-empty}]: ")" NEW_REPO

  NEW_ORG="${NEW_ORG:-$GITHUB_ORG}"
  NEW_REPO="${NEW_REPO:-$GITHUB_REPO}"

  if [ -z "$NEW_ORG" ] || [ -z "$NEW_REPO" ]; then
    echo -e "\n  ${RED}[ERROR]${NC} Both fields are required. No changes made."
    read -p "  Press Enter..." _; return
  fi

  sed -i "s|^GITHUB_ORG=.*|GITHUB_ORG=\"${NEW_ORG}\"|" "$CONF_FILE"
  sed -i "s|^GITHUB_REPO=.*|GITHUB_REPO=\"${NEW_REPO}\"|" "$CONF_FILE"

  echo ""
  echo -e "  ${GREEN}[OK]${NC}  Saved:"
  echo -e "  ${GRAY}GITHUB_ORG  :${NC} ${NEW_ORG}"
  echo -e "  ${GRAY}GITHUB_REPO :${NC} ${NEW_REPO}"
  echo ""
  read -p "  Press Enter..." _
}

menu_setup() {
  while true; do
    print_header
    echo -e "  ${BOLD}${BLUE}[ SETUP ]${NC}"
    echo ""
    echo -e "  ${CYAN}01${NC}  IAM + OIDC        roles, deploy policy, ECS roles"
    echo -e "  ${CYAN}02${NC}  Network           VPC, subnets, security groups"
    echo -e "  ${CYAN}03${NC}  ECR               Docker registry + lifecycle policy"
    echo -e "  ${CYAN}04${NC}  ECS Fargate       cluster, service, ALB, task definition"
    echo -e "  ${CYAN}05${NC}  Pipeline          GitHub Actions + secret instructions"
    echo -e "  ${CYAN}06${NC}  Monitoring        CloudWatch alarms + SNS"
    echo ""
    echo -e "  ${GRAY}0   Back${NC}"
    echo ""
    read -p "$(echo -e "  ${BOLD}Select:${NC} ")" OPT
    case $OPT in
      1|01) run_script "01-setup-iam.sh" ;;
      2|02) run_script "02-setup-network.sh" ;;
      3|03) run_script "03-setup-ecr.sh" ;;
      4|04) run_script "04-setup-ecs.sh" ;;
      5|05) run_script "05-setup-pipeline.sh" ;;
      6|06) run_script "06-setup-monitoring.sh" ;;
      0)    return ;;
      *)    echo -e "\n  ${RED}Invalid.${NC}"; sleep 1 ;;
    esac
  done
}

menu_simulate() {
  while true; do
    print_header
    echo -e "  ${BOLD}${YELLOW}[ SIMULATION ]${NC}"
    echo ""
    echo -e "  ${CYAN}10${NC}  Deploy simulation   bump version → push → watch pipeline"
    echo -e "  ${CYAN}11${NC}  Rollback simulation break /health → ECS fails → rollback"
    echo ""
    echo -e "  ${GRAY}0   Back${NC}"
    echo ""
    read -p "$(echo -e "  ${BOLD}Select:${NC} ")" OPT
    case $OPT in
      10) run_script "10-deploy-simulation.sh" ;;
      11) run_script "11-rollback-simulation.sh" ;;
      0)  return ;;
      *)  echo -e "\n  ${RED}Invalid.${NC}"; sleep 1 ;;
    esac
  done
}

menu_cleanup() {
  while true; do
    print_header
    echo -e "  ${BOLD}${RED}[ CLEANUP ]${NC}"
    echo ""
    echo -e "  ${RED}99${NC}  Delete everything   all AWS resources + restore config.env"
    echo ""
    echo -e "  ${GRAY}Or delete selectively:${NC}"
    echo -e "  ${CYAN}91${NC}  ECS service + cluster only"
    echo -e "  ${CYAN}92${NC}  ALB + target group only"
    echo -e "  ${CYAN}93${NC}  ECR repository only"
    echo -e "  ${CYAN}94${NC}  IAM roles only"
    echo ""
    echo -e "  ${GRAY}0   Back${NC}"
    echo ""
    read -p "$(echo -e "  ${BOLD}Select:${NC} ")" OPT

    source "$CONF_FILE" 2>/dev/null
    R="--region ${AWS_REGION}"

    case $OPT in
      99) run_script "99-cleanup.sh" ;;
      91)
        echo ""
        aws ecs update-service $R \
          --cluster "${ECS_CLUSTER_NAME}" \
          --service "${ECS_SERVICE_NAME}" \
          --desired-count 0 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} Scaled to 0." || true
        sleep 5
        aws ecs delete-service $R \
          --cluster "${ECS_CLUSTER_NAME}" \
          --service "${ECS_SERVICE_NAME}" \
          --force 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} Service deleted." || \
          echo -e "  ${YELLOW}[SKIP]${NC} Not found."
        aws ecs delete-cluster $R \
          --cluster "${ECS_CLUSTER_NAME}" 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} Cluster deleted." || \
          echo -e "  ${YELLOW}[SKIP]${NC} Not found."
        read -p "  Press Enter..." _
        ;;
      92)
        echo ""
        [ -n "${ALB_ARN:-}" ] && \
          aws elbv2 delete-load-balancer $R \
            --load-balancer-arn "${ALB_ARN}" 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} ALB deleted." || \
          echo -e "  ${YELLOW}[SKIP]${NC} ALB not found."
        sleep 20
        [ -n "${TG_ARN:-}" ] && \
          aws elbv2 delete-target-group $R \
            --target-group-arn "${TG_ARN}" 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} Target group deleted." || \
          echo -e "  ${YELLOW}[SKIP]${NC} Not found."
        read -p "  Press Enter..." _
        ;;
      93)
        echo ""
        aws ecr delete-repository $R \
          --repository-name "${ECR_REPO_NAME}" \
          --force 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} ECR repository deleted." || \
          echo -e "  ${YELLOW}[SKIP]${NC} Not found."
        read -p "  Press Enter..." _
        ;;
      94)
        echo ""
        POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity \
          --query Account --output text):policy/${IAM_POLICY_NAME}"
        for ROLE in "${GITHUB_OIDC_ROLE_NAME}" \
                    "${ECS_EXECUTION_ROLE_NAME}" \
                    "${ECS_TASK_ROLE_NAME}"; do
          aws iam delete-role --role-name "${ROLE}" 2>/dev/null && \
            echo -e "  ${GREEN}[OK]${NC} Role deleted: ${ROLE}" || \
            echo -e "  ${YELLOW}[SKIP]${NC} Not found: ${ROLE}"
        done
        aws iam delete-policy --policy-arn "${POLICY_ARN}" 2>/dev/null && \
          echo -e "  ${GREEN}[OK]${NC} Policy deleted." || \
          echo -e "  ${YELLOW}[SKIP]${NC} Policy not found."
        read -p "  Press Enter..." _
        ;;
      0) return ;;
      *) echo -e "\n  ${RED}Invalid.${NC}"; sleep 1 ;;
    esac
  done
}

# ── Main ──────────────────────────────────────
while true; do
  print_header
  echo -e "  ${BOLD}What do you want to do?${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}1${NC}  Setup         scripts 01-06"
  echo -e "  ${YELLOW}${BOLD}2${NC}  Simulation    scripts 10-11"
  echo -e "  ${RED}${BOLD}3${NC}  Cleanup       script 99"
  echo ""
  echo -e "  ${GRAY}c   Configure GitHub user/repo${NC}"
  echo -e "  ${GRAY}q   Exit${NC}"
  echo ""
  read -p "$(echo -e "  ${BOLD}Select:${NC} ")" OPT
  case $OPT in
    1) menu_setup ;;
    2) menu_simulate ;;
    3) menu_cleanup ;;
    c|C) configure_github ;;
    q|Q) echo -e "\n  ${GRAY}Goodbye.${NC}\n"; exit 0 ;;
    *) echo -e "\n  ${RED}Invalid.${NC}"; sleep 1 ;;
  esac
done
