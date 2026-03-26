#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  02-setup-network.sh
#  Crea la red para el ejercicio DevOps:
#    1. VPC con dos subnets publicas (2 AZs)
#    2. Internet Gateway + Route table
#    3. Security Group para el ALB (inbound 80/443)
#    4. Security Group para ECS (solo desde el ALB)
#
#  Diferencia clave vs el ejercicio de seguridad:
#  - Dos subnets en AZs distintas desde el inicio
#    (ECS Fargate con alta disponibilidad)
#  - SG de ECS solo acepta trafico desde el SG del ALB
#    (los containers nunca expuestos directamente)
#
#  Uso:
#    chmod +x 02-setup-network.sh
#    ./02-setup-network.sh
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
echo -e "${BOLD}║      02 — Network setup                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_info "VPC CIDR    : ${VPC_CIDR}"
log_info "Subnet 1    : ${SUBNET_PUBLIC_1_CIDR} (${AZ_1})"
log_info "Subnet 2    : ${SUBNET_PUBLIC_2_CIDR} (${AZ_2})"
log_info "Region      : ${AWS_REGION}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ── 1. VPC ────────────────────────────────────
log_step "1/5 — Creating VPC..."

EXISTING_VPC=$(aws ec2 describe-vpcs $R \
  --filters "Name=tag:Name,Values=${VPC_NAME}" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_VPC" ]; then
  VPC_ID="$EXISTING_VPC"
  log_warn "VPC already exists: ${VPC_ID}"
else
  VPC_ID=$(aws ec2 create-vpc $R \
    --cidr-block "${VPC_CIDR}" \
    --query 'Vpc.VpcId' --output text)
  aws ec2 create-tags $R --resources "${VPC_ID}" \
    --tags Key=Name,Value="${VPC_NAME}" Key=Project,Value="${PROJECT_NAME}"
  aws ec2 modify-vpc-attribute $R \
    --vpc-id "${VPC_ID}" --enable-dns-hostnames
  aws ec2 modify-vpc-attribute $R \
    --vpc-id "${VPC_ID}" --enable-dns-support
  log_success "VPC created: ${VPC_ID}"
fi

grep -q "^VPC_ID=" "$CONF_FILE" && \
  sed -i "s|^VPC_ID=.*|VPC_ID=\"${VPC_ID}\"|" "$CONF_FILE" || \
  echo "VPC_ID=\"${VPC_ID}\"" >> "$CONF_FILE"

# ── 2. Subnets ────────────────────────────────
log_step "2/5 — Creating public subnets (2 AZs)..."

EXISTING_SUBNET1=$(aws ec2 describe-subnets $R \
  --filters "Name=tag:Name,Values=${VPC_NAME}-public-1" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_SUBNET1" ]; then
  SUBNET_PUBLIC_1_ID="$EXISTING_SUBNET1"
  log_warn "Subnet 1 already exists: ${SUBNET_PUBLIC_1_ID}"
else
  SUBNET_PUBLIC_1_ID=$(aws ec2 create-subnet $R \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${SUBNET_PUBLIC_1_CIDR}" \
    --availability-zone "${AZ_1}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags $R --resources "${SUBNET_PUBLIC_1_ID}" \
    --tags Key=Name,Value="${VPC_NAME}-public-1" Key=Project,Value="${PROJECT_NAME}"
  aws ec2 modify-subnet-attribute $R \
    --subnet-id "${SUBNET_PUBLIC_1_ID}" --map-public-ip-on-launch
  log_success "Subnet 1 created: ${SUBNET_PUBLIC_1_ID} (${AZ_1})"
fi

EXISTING_SUBNET2=$(aws ec2 describe-subnets $R \
  --filters "Name=tag:Name,Values=${VPC_NAME}-public-2" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_SUBNET2" ]; then
  SUBNET_PUBLIC_2_ID="$EXISTING_SUBNET2"
  log_warn "Subnet 2 already exists: ${SUBNET_PUBLIC_2_ID}"
else
  SUBNET_PUBLIC_2_ID=$(aws ec2 create-subnet $R \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${SUBNET_PUBLIC_2_CIDR}" \
    --availability-zone "${AZ_2}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags $R --resources "${SUBNET_PUBLIC_2_ID}" \
    --tags Key=Name,Value="${VPC_NAME}-public-2" Key=Project,Value="${PROJECT_NAME}"
  aws ec2 modify-subnet-attribute $R \
    --subnet-id "${SUBNET_PUBLIC_2_ID}" --map-public-ip-on-launch
  log_success "Subnet 2 created: ${SUBNET_PUBLIC_2_ID} (${AZ_2})"
fi

grep -q "^SUBNET_PUBLIC_1_ID=" "$CONF_FILE" && \
  sed -i "s|^SUBNET_PUBLIC_1_ID=.*|SUBNET_PUBLIC_1_ID=\"${SUBNET_PUBLIC_1_ID}\"|" "$CONF_FILE" || \
  echo "SUBNET_PUBLIC_1_ID=\"${SUBNET_PUBLIC_1_ID}\"" >> "$CONF_FILE"
grep -q "^SUBNET_PUBLIC_2_ID=" "$CONF_FILE" && \
  sed -i "s|^SUBNET_PUBLIC_2_ID=.*|SUBNET_PUBLIC_2_ID=\"${SUBNET_PUBLIC_2_ID}\"|" "$CONF_FILE" || \
  echo "SUBNET_PUBLIC_2_ID=\"${SUBNET_PUBLIC_2_ID}\"" >> "$CONF_FILE"

# ── 3. Internet Gateway + Route Table ─────────
log_step "3/5 — Creating Internet Gateway and route table..."

EXISTING_IGW=$(aws ec2 describe-internet-gateways $R \
  --filters "Name=tag:Name,Values=${VPC_NAME}-igw" \
  --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_IGW" ]; then
  IGW_ID="$EXISTING_IGW"
  log_warn "IGW already exists: ${IGW_ID}"
else
  IGW_ID=$(aws ec2 create-internet-gateway $R \
    --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 create-tags $R --resources "${IGW_ID}" \
    --tags Key=Name,Value="${VPC_NAME}-igw" Key=Project,Value="${PROJECT_NAME}"
  aws ec2 attach-internet-gateway $R \
    --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
  log_success "IGW created and attached: ${IGW_ID}"
fi

RTB_ID=$(aws ec2 describe-route-tables $R \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${VPC_NAME}-rtb" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -z "$RTB_ID" ]; then
  RTB_ID=$(aws ec2 create-route-table $R \
    --vpc-id "${VPC_ID}" --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-tags $R --resources "${RTB_ID}" \
    --tags Key=Name,Value="${VPC_NAME}-rtb" Key=Project,Value="${PROJECT_NAME}"
  aws ec2 create-route $R \
    --route-table-id "${RTB_ID}" \
    --destination-cidr-block "0.0.0.0/0" --gateway-id "${IGW_ID}"
  aws ec2 associate-route-table $R \
    --route-table-id "${RTB_ID}" --subnet-id "${SUBNET_PUBLIC_1_ID}"
  aws ec2 associate-route-table $R \
    --route-table-id "${RTB_ID}" --subnet-id "${SUBNET_PUBLIC_2_ID}"
  log_success "Route table created: ${RTB_ID} (associated with both subnets)"
else
  log_warn "Route table already exists: ${RTB_ID}"
fi

# ── 4. Security Group — ALB ───────────────────
log_step "4/5 — Creating Security Group for ALB..."

EXISTING_SG_ALB=$(aws ec2 describe-security-groups $R \
  --filters "Name=tag:Name,Values=${SG_ALB_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_SG_ALB" ]; then
  SG_ALB_ID="$EXISTING_SG_ALB"
  log_warn "ALB Security Group already exists: ${SG_ALB_ID}"
else
  SG_ALB_ID=$(aws ec2 create-security-group $R \
    --group-name "${SG_ALB_NAME}" \
    --description "ALB SG - allows inbound HTTP and HTTPS from internet" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)
  aws ec2 create-tags $R --resources "${SG_ALB_ID}" \
    --tags Key=Name,Value="${SG_ALB_NAME}" Key=Project,Value="${PROJECT_NAME}"

  aws ec2 authorize-security-group-ingress $R \
    --group-id "${SG_ALB_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0
  log_info "  Inbound: TCP 80 from 0.0.0.0/0"

  aws ec2 authorize-security-group-ingress $R \
    --group-id "${SG_ALB_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0
  log_info "  Inbound: TCP 443 from 0.0.0.0/0"

  log_success "ALB Security Group created: ${SG_ALB_ID}"
fi

grep -q "^SG_ALB_ID=" "$CONF_FILE" && \
  sed -i "s|^SG_ALB_ID=.*|SG_ALB_ID=\"${SG_ALB_ID}\"|" "$CONF_FILE" || \
  echo "SG_ALB_ID=\"${SG_ALB_ID}\"" >> "$CONF_FILE"

# ── 5. Security Group — ECS ───────────────────
log_step "5/5 — Creating Security Group for ECS tasks..."

EXISTING_SG_ECS=$(aws ec2 describe-security-groups $R \
  --filters "Name=tag:Name,Values=${SG_ECS_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v "None" || echo "")

if [ -n "$EXISTING_SG_ECS" ]; then
  SG_ECS_ID="$EXISTING_SG_ECS"
  log_warn "ECS Security Group already exists: ${SG_ECS_ID}"
else
  SG_ECS_ID=$(aws ec2 create-security-group $R \
    --group-name "${SG_ECS_NAME}" \
    --description "ECS SG - allows inbound only from ALB security group" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)
  aws ec2 create-tags $R --resources "${SG_ECS_ID}" \
    --tags Key=Name,Value="${SG_ECS_NAME}" Key=Project,Value="${PROJECT_NAME}"

  # Only allow traffic FROM the ALB security group — not from the internet directly
  aws ec2 authorize-security-group-ingress $R \
    --group-id "${SG_ECS_ID}" \
    --protocol tcp --port "${APP_PORT}" \
    --source-group "${SG_ALB_ID}"
  log_info "  Inbound: TCP ${APP_PORT} from ALB SG only (${SG_ALB_ID})"
  log_info "  Containers are NOT reachable directly from the internet"

  # Outbound: allow all (ECR pull, CloudWatch, SSM, internet)
  log_info "  Outbound: all traffic (ECR pull + CloudWatch + SSM)"

  log_success "ECS Security Group created: ${SG_ECS_ID}"
fi

grep -q "^SG_ECS_ID=" "$CONF_FILE" && \
  sed -i "s|^SG_ECS_ID=.*|SG_ECS_ID=\"${SG_ECS_ID}\"|" "$CONF_FILE" || \
  echo "SG_ECS_ID=\"${SG_ECS_ID}\"" >> "$CONF_FILE"

# ── Summary ───────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  02 — Network setup completed            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log_success "VPC         : ${VPC_ID} (${VPC_CIDR})"
log_success "Subnet 1    : ${SUBNET_PUBLIC_1_ID} (${AZ_1})"
log_success "Subnet 2    : ${SUBNET_PUBLIC_2_ID} (${AZ_2})"
log_success "IGW         : ${IGW_ID}"
log_success "Route table : ${RTB_ID}"
log_success "SG ALB      : ${SG_ALB_ID}"
log_success "SG ECS      : ${SG_ECS_ID}"
echo ""
echo -e "${CYAN}${BOLD}── How to verify in the AWS Console ────────────────${NC}"
echo ""
echo -e "  ${BOLD}1. VPC${NC}"
echo -e "     VPC → Your VPCs → search '${VPC_NAME}'"
echo -e "     ${YELLOW}→ 2 subnets · DNS hostnames enabled${NC}"
echo ""
echo -e "  ${BOLD}2. Security Groups${NC}"
echo -e "     EC2 → Security Groups"
echo -e "     ${YELLOW}→ ALB SG: inbound 80+443 from 0.0.0.0/0${NC}"
echo -e "     ${YELLOW}→ ECS SG: inbound ${APP_PORT} from ALB SG only${NC}"
echo -e "     ${YELLOW}→ This means containers are not internet-accessible directly${NC}"
echo ""
echo -e "  ${BOLD}3. Key concept — SG chaining${NC}"
echo -e "     ${YELLOW}→ ECS SG source = ALB SG (not a CIDR range)${NC}"
echo -e "     ${YELLOW}→ Any instance in the ALB SG can reach ECS on port ${APP_PORT}${NC}"
echo -e "     ${YELLOW}→ Nothing else can — even if it knows the container IP${NC}"
echo ""