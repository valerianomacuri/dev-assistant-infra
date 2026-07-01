#!/usr/bin/env bash
# Construye y sube la imagen placeholder (placeholder/) al ECR del stack
# bootstrap "ecr" (templates/bootstrap/ecr.yml), como tag `:latest`. Paso
# manual, único, parte de la puesta en marcha: se corre después de desplegar
# el stack ecr y antes de dejar correr el CI de infra, así backend-service
# puede arrancar con DesiredCount: 1 desde su primer deploy. El primer push
# real del CI del backend sobreescribe este mismo tag `:latest`.
#
#   scripts/push-placeholder.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-dev-assistant}"
STACK="${PROJECT}-ecr"

REPO_URI="$(aws cloudformation describe-stacks --region "$REGION" \
  --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`EcrRepositoryUri`].OutputValue' \
  --output text 2>/dev/null || true)"

if [ -z "$REPO_URI" ] || [ "$REPO_URI" = "None" ]; then
  echo "No se encontró el output EcrRepositoryUri del stack ${STACK}." >&2
  echo "Desplegá primero: bash scripts/cfn.sh deploy ecr" >&2
  exit 1
fi

REGISTRY="${REPO_URI%%/*}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Login en ${REGISTRY}..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Build de la imagen placeholder..."
docker build -t "${REPO_URI}:latest" "${SCRIPT_DIR}/../placeholder"

echo "Push a ${REPO_URI}:latest..."
docker push "${REPO_URI}:latest"

echo "OK. ${REPO_URI}:latest listo para el primer deploy de backend-service."
