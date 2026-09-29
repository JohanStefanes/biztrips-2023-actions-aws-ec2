#!/usr/bin/env bash
# EX-03: ECR, CloudWatch-Log-Group, ECS-Cluster, ALB + Target Group, Security Groups
# und ECS-Service (Fargate, 2 Tasks) im Default-VPC anlegen. Idempotent – kann erneut laufen.
# Voraussetzung: gültige AWS-Zugangsdaten (Learner Lab) und laufendes Docker (für das erste Image).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
REPO=biztrips
CLUSTER=biztrips-cluster
SERVICE=biztrips-service
cd "$(dirname "$0")/../.."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "== Schritt 1: ECR-Repository"
aws ecr describe-repositories --repository-names "$REPO" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$REPO" >/dev/null

echo "== Erstes Image nach ECR pushen (Service braucht ein vorhandenes Image)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 \
  --build-arg VITE_BUILD_SHA="$(git rev-parse --short HEAD)" --build-arg VITE_DEPLOY_TARGET=ecs \
  -t "$REGISTRY/$REPO:latest" .
docker push "$REGISTRY/$REPO:latest"

echo "== Log-Group"
aws logs create-log-group --log-group-name /ecs/biztrips 2>/dev/null || true

echo "== Schritt 3: ECS-Cluster"
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

echo "== Schritt 4: Netzwerk, Security Groups, ALB, Target Group"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
# Zwei Default-Subnets in unterschiedlichen AZs (ALB-Voraussetzung), us-east-1e unterstützt nicht alles.
read -r SUBNET_A SUBNET_B < <(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'sort_by(Subnets[?AvailabilityZone!=`us-east-1e`],&AvailabilityZone)[:2].SubnetId' --output text)

sg() { # sg <name> <beschreibung>
  local id
  id=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$1" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ]; then
    id=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" --query GroupId --output text)
  fi
  echo "$id"
}
SG_ALB=$(sg biztrips-alb-sg "biztrips ALB: HTTP aus dem Internet")
SG_TASKS=$(sg biztrips-tasks-sg "biztrips Fargate-Tasks: HTTP nur vom ALB")
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_TASKS" --protocol tcp --port 80 --source-group "$SG_ALB" >/dev/null 2>&1 || true

TG_ARN=$(aws elbv2 create-target-group --name biztrips-tg --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
  --target-type ip --health-check-path / --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB_ARN=$(aws elbv2 create-load-balancer --name biztrips-alb --subnets "$SUBNET_A" "$SUBNET_B" \
  --security-groups "$SG_ALB" --scheme internet-facing --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[0]' --output text | grep -q . \
  || aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
       --default-actions Type=forward,TargetGroupArn="$TG_ARN" >/dev/null
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)

echo "== Schritt 5: Task-Definition registrieren"
sed -e "s/AWS_ACCOUNT_ID/$ACCOUNT_ID/g" -e "s/AWS_REGION/$REGION/g" task-definition.json > /tmp/biztrips-taskdef.json
aws ecs register-task-definition --cli-input-json file:///tmp/biztrips-taskdef.json >/dev/null

echo "== Schritt 6: ECS-Service"
STATUS=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].status' --output text 2>/dev/null || echo None)
if [ "$STATUS" != "ACTIVE" ]; then
  aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" --task-definition biztrips \
    --desired-count 2 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$SG_TASKS],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=biztrips,containerPort=80" >/dev/null
fi
echo "Warte, bis der Service stabil ist ..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

echo
echo "ECR:     $REGISTRY/$REPO"
echo "Website: http://$ALB_DNS"
