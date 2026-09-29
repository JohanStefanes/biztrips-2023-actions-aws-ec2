#!/usr/bin/env bash
# EX-01: EC2-Instanz (Ubuntu 24.04) mit nginx für die statische biztrips-App anlegen.
# Voraussetzung: gültige AWS-Zugangsdaten (Learner Lab → AWS Details → AWS CLI in ~/.aws/credentials).
# Aufruf: scripts/aws/ec2-setup.sh [KEY_PAIR_NAME]   (Default: vockey = Learner-Lab-Key)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${1:-vockey}"
NAME=biztrips-ec2
export AWS_DEFAULT_REGION="$REGION"

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$NAME-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$NAME-sg" --description "biztrips EC2: SSH + HTTP" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  # Port 22 offen, weil die IPs der GitHub-hosted Runner wechseln.
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
fi

AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

USER_DATA=$(cat <<'UD'
#!/bin/bash
set -eux
apt-get update
apt-get install -y nginx rsync
mkdir -p /var/www/biztrips
echo '<h1>biztrips – wartet auf ersten Deploy</h1>' > /var/www/biztrips/index.html
chown -R ubuntu:ubuntu /var/www/biztrips
cat > /etc/nginx/sites-available/biztrips <<'NGINX'
server {
    listen 80;
    server_name _;
    root /var/www/biztrips;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/biztrips /etc/nginx/sites-enabled/biztrips
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
UD
)

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$NAME" Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$INSTANCE_ID" = "None" ]; then
  INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
else
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null || true
fi

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
HOST=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicDnsName' --output text)

echo
echo "Instanz:   $INSTANCE_ID"
echo "EC2_HOST:  $HOST"
echo "EC2_USER:  ubuntu"
echo "Website:   http://$HOST  (nginx ist nach ca. 1-2 Minuten bereit)"
