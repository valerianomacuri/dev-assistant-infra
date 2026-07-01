#!/usr/bin/env bash
# Helpers de CloudFormation para el CI/CD de infra (los usa deploy-infra.yml).
#
#   scripts/cfn.sh validate             cfn validate-template de los 7 templates.
#   scripts/cfn.sh changeset <slug>     Crea un change set (preview del diff),
#                                       lo vuelca y lo borra. No cambia nada.
#   scripts/cfn.sh deploy   <slug>      Despliega el stack (idempotente).
#   scripts/cfn.sh destroy  <slug>      Borra el stack (idempotente: si no
#                                       existe, no falla). Si <slug> es "ecr"
#                                       vacía el repositorio antes, porque
#                                       CloudFormation no borra un
#                                       AWS::ECR::Repository con imágenes.
#   scripts/cfn.sh destroy-all          Borra los 7 stacks CI-managed en orden
#                                       inverso al de deploy-infra.yml. No
#                                       toca "bootstrap" (manual).
#
# <slug> es el nombre lógico del template (ya no coincide 1:1 con la ruta del
# archivo: los templates viven repartidos en templates/{bootstrap,infra,app}/
# con extensión .yaml o .yml según el archivo). Ver template_path().
#
#   bootstrap  (bootstrap MANUAL: OIDC + InfraDeployRole + DeployRole; el CI no
#              lo despliega, solo lo valida)
#   network | security | ecr | ecs-cluster | alb | observability | backend-service
#              (los gestiona el CI, en ese orden: network y security antes de
#              alb; ecs-cluster y alb antes de observability y backend-service)
#
# Los params ESTÁTICOS van en params/*.json. Variables: AWS_REGION (def.
# us-east-1), PROJECT_NAME (def. dev-assistant).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-dev-assistant}"
SLUGS=(bootstrap network security ecr ecs-cluster alb observability backend-service)

# Mapea slug -> ruta real del template.
template_path() {
  case "$1" in
    bootstrap)       echo "templates/bootstrap/github-oidc.yml" ;;
    network)         echo "templates/infra/network.yaml" ;;
    security)        echo "templates/infra/security.yml" ;;
    ecr)             echo "templates/infra/ecr.yml" ;;
    ecs-cluster)      echo "templates/infra/ecs-cluster.yml" ;;
    alb)              echo "templates/infra/alb.yml" ;;
    observability)    echo "templates/infra/observability.yml" ;;
    backend-service)  echo "templates/app/backend-service.yml" ;;
    *) echo "slug desconocido: $1" >&2; return 1 ;;
  esac
}

# Mapea slug -> nombre de stack y capabilities requeridas.
stack_name() {
  case "$1" in
    bootstrap)       echo "${PROJECT}-cicd-infra" ;;
    network)         echo "${PROJECT}-network" ;;
    security)        echo "${PROJECT}-security" ;;
    ecr)             echo "${PROJECT}-ecr" ;;
    ecs-cluster)      echo "${PROJECT}-ecs-cluster" ;;
    alb)              echo "${PROJECT}-alb" ;;
    observability)    echo "${PROJECT}-observability" ;;
    backend-service)  echo "${PROJECT}-backend-service" ;;
    *) echo "slug desconocido: $1" >&2; return 1 ;;
  esac
}
stack_caps() {
  case "$1" in
    bootstrap|ecs-cluster|backend-service) echo "CAPABILITY_NAMED_IAM" ;;
    *) echo "" ;;
  esac
}

validate() {
  for slug in "${SLUGS[@]}"; do
    echo "validate-template: ${slug}"
    aws cloudformation validate-template --region "$REGION" \
      --template-body "file://$(template_path "$slug")" >/dev/null
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
      --template-body "file://$(template_path "$slug")" \
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
    --template-file "$(template_path "$slug")" \
    --parameter-overrides "${overrides[@]}" \
    --no-fail-on-empty-changeset \
    ${caps:+--capabilities $caps}
  echo "${stack} OK."
}

# Vacía un repo ECR (borra todas las imágenes) para que el delete-stack no
# falle con "repository not empty".
empty_ecr() {
  local repo="$1" digests
  digests="$(aws ecr list-images --region "$REGION" --repository-name "$repo" \
    --query 'imageIds[*]' --output json 2>/dev/null || echo '[]')"
  if [ "$digests" != "[]" ] && [ -n "$digests" ]; then
    echo "Vaciando repo ECR ${repo}..."
    aws ecr batch-delete-image --region "$REGION" --repository-name "$repo" \
      --image-ids "$digests" >/dev/null
  fi
}

destroy() {
  local slug="$1" stack
  stack="$(stack_name "$slug")"
  if ! aws cloudformation describe-stacks --region "$REGION" \
      --stack-name "$stack" >/dev/null 2>&1; then
    echo "${stack} no existe, nada que borrar."
    return 0
  fi
  if [ "$slug" = "ecr" ]; then
    empty_ecr "$(aws cloudformation describe-stacks --region "$REGION" \
      --stack-name "$stack" --query 'Stacks[0].Outputs[?OutputKey==`EcrRepositoryName`].OutputValue' \
      --output text)"
  fi
  echo "Borrando ${stack}..."
  aws cloudformation delete-stack --region "$REGION" --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$stack"
  echo "${stack} borrado."
}

destroy_all() {
  local i slug
  for (( i=${#SLUGS[@]}-1; i>=0; i-- )); do
    slug="${SLUGS[$i]}"
    [ "$slug" = "bootstrap" ] && continue
    destroy "$slug"
  done
}

cmd="${1:-}"
case "$cmd" in
  validate)    validate ;;
  changeset)   changeset "${2:?falta <slug>}" ;;
  deploy)      deploy "${2:?falta <slug>}" ;;
  destroy)     destroy "${2:?falta <slug>}" ;;
  destroy-all) destroy_all ;;
  *) echo "uso: scripts/cfn.sh {validate|changeset <slug>|deploy <slug>|destroy <slug>|destroy-all}" >&2; exit 1 ;;
esac
