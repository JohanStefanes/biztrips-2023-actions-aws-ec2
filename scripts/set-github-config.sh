#!/usr/bin/env bash
# Setzt die GitHub-Secrets/-Variables für die Pipeline. Selbst ausführen (Werte werden abgefragt,
# AWS-Werte aus ~/.aws/credentials [default] gelesen – nach jedem Learner-Lab-Start erneut laufen lassen).
# Aufruf: scripts/set-github-config.sh ec2|dockerhub|aws
set -euo pipefail

case "${1:-}" in
  ec2)
    read -rp "EC2_HOST (Public DNS): " host
    read -rp "Pfad zur .pem-Datei [~/Downloads/labsuser.pem]: " pem
    pem="${pem:-$HOME/Downloads/labsuser.pem}"
    gh secret set EC2_HOST --body "$host"
    gh secret set EC2_USER --body ubuntu
    gh secret set EC2_SSH_KEY < "${pem/#\~/$HOME}"
    gh variable set EC2_PUBLIC_HOST --body "$host"
    gh variable set ENABLE_EC2_DEPLOY --body true
    ;;
  dockerhub)
    read -rp "Docker-Hub-Benutzername: " user
    gh secret set DOCKERHUB_USERNAME --body "$user"
    echo "Docker-Hub-Access-Token (Read & Write) einfügen, dann Enter + Ctrl-D:"
    gh secret set DOCKERHUB_TOKEN
    gh variable set ENABLE_DOCKERHUB_PUSH --body true
    ;;
  aws)
    for k in aws_access_key_id aws_secret_access_key aws_session_token; do
      v=$(aws configure get "$k")
      gh secret set "$(echo "$k" | tr '[:lower:]' '[:upper:]')" --body "$v"
    done
    read -rp "ALB-DNS (aus ecs-setup.sh, leer lassen = unverändert): " alb
    [ -n "$alb" ] && gh variable set ECS_ALB_DNS --body "$alb"
    gh variable set ENABLE_ECS_DEPLOY --body true
    ;;
  *) echo "Aufruf: $0 ec2|dockerhub|aws"; exit 1 ;;
esac
