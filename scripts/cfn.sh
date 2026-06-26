#!/usr/bin/env bash
# Helpers de CloudFormation para el CI/CD de infra (los usa deploy-infra.yml).
#
#   scripts/cfn.sh validate             cfn validate-template de los 3 templates.
#   scripts/cfn.sh changeset <slug>     Crea un change set (preview del diff),
#                                       lo vuelca y lo borra. No cambia nada.
#   scripts/cfn.sh deploy   <slug>      Despliega el stack (idempotente).
#
# <slug> es el nombre base de template/params:
#   00-cicd-infra  (bootstrap MANUAL: OIDC + InfraDeployRole; el CI no lo toca)
#   01-network | 02-cicd-backend | 03-service  (los gestiona el CI)
# Los params ESTÁTICOS van en params/*.json. Los específicos de cuenta/entorno
# (GitHubOrg, DomainName, ImageUri) los resuelve CloudFormation directamente desde
# SSM Parameter Store (parámetros de tipo AWS::SSM::Parameter::Value en los
# templates, Default = /dev-assistant/cfn/<clave>): no se pasan aquí.
# Variables: AWS_REGION (def. us-east-1), PROJECT_NAME (def. dev-assistant).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-dev-assistant}"
SLUGS=(00-cicd-infra 01-network 02-cicd-backend 03-service)

# Mapea slug -> nombre de stack y capabilities requeridas.
stack_name() {
  case "$1" in
    00-cicd-infra)   echo "${PROJECT}-cicd-infra" ;;
    01-network)      echo "${PROJECT}-network" ;;
    02-cicd-backend) echo "${PROJECT}-cicd-backend" ;;
    03-service)      echo "${PROJECT}-service" ;;
    *) echo "slug desconocido: $1" >&2; return 1 ;;
  esac
}
stack_caps() {
  case "$1" in
    00-cicd-infra|02-cicd-backend|03-service) echo "CAPABILITY_NAMED_IAM" ;;
    *) echo "" ;;
  esac
}

validate() {
  for slug in "${SLUGS[@]}"; do
    echo "validate-template: ${slug}"
    aws cloudformation validate-template --region "$REGION" \
      --template-body "file://templates/${slug}.yaml" >/dev/null
  done
  echo "Todos los templates son válidos."
}

changeset() {
  local slug="$1" stack caps cstype name reason
  stack="$(stack_name "$slug")"
  caps="$(stack_caps "$slug")"
  if aws cloudformation describe-stacks --region "$REGION" \
      --stack-name "$stack" >/dev/null 2>&1; then
    cstype=UPDATE
  else
    cstype=CREATE
  fi
  name="ci-$(date +%s)"

  echo "### \`${stack}\` — change set (${cstype})"
  echo ""
  if ! aws cloudformation create-change-set \
      --region "$REGION" --stack-name "$stack" --change-set-name "$name" \
      --change-set-type "$cstype" \
      --template-body "file://templates/${slug}.yaml" \
      --parameters "file://params/${slug}.json" \
      ${caps:+--capabilities $caps} >/dev/null 2>cs.err; then
    echo '_No se pudo crear el change set (¿faltan stacks dependientes aún sin desplegar?):_'
    echo '```'; cat cs.err; echo '```'; echo ""
    return 0
  fi

  if aws cloudformation wait change-set-create-complete \
      --region "$REGION" --stack-name "$stack" --change-set-name "$name" 2>/dev/null; then
    echo '```'
    aws cloudformation describe-change-set --region "$REGION" \
      --stack-name "$stack" --change-set-name "$name" \
      --query 'Changes[].ResourceChange.{Action:Action,Type:ResourceType,LogicalId:LogicalResourceId,Replacement:Replacement}' \
      --output table
    echo '```'
  else
    reason="$(aws cloudformation describe-change-set --region "$REGION" \
      --stack-name "$stack" --change-set-name "$name" \
      --query StatusReason --output text 2>/dev/null || true)"
    case "$reason" in
      *"didn't contain changes"*|*"o updates"*) echo '_Sin cambios._' ;;
      *) echo "_Change set FAILED:_ ${reason}" ;;
    esac
  fi
  echo ""
  aws cloudformation delete-change-set --region "$REGION" \
    --stack-name "$stack" --change-set-name "$name" >/dev/null 2>&1 || true
}

deploy() {
  local slug="$1" stack caps
  stack="$(stack_name "$slug")"
  caps="$(stack_caps "$slug")"
  # JSON estructurado -> Key=Value. La expansión con comillas del array evita el
  # word-splitting y el globbing (p.ej. CorsOrigins=*).
  local overrides=()
  mapfile -t overrides < <(jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' "params/${slug}.json")
  echo "Desplegando ${stack}..."
  aws cloudformation deploy \
    --region "$REGION" --stack-name "$stack" \
    --template-file "templates/${slug}.yaml" \
    --parameter-overrides "${overrides[@]}" \
    --no-fail-on-empty-changeset \
    ${caps:+--capabilities $caps}
  echo "${stack} OK."
}

cmd="${1:-}"
case "$cmd" in
  validate)  validate ;;
  changeset) changeset "${2:?falta <slug>}" ;;
  deploy)    deploy "${2:?falta <slug>}" ;;
  *) echo "uso: scripts/cfn.sh {validate|changeset <slug>|deploy <slug>}" >&2; exit 1 ;;
esac
