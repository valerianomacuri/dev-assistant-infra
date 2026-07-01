# Guía de despliegue — dev-assistant-infra

Checklist práctico para levantar toda la infraestructura **de cero** y dejar la API
respondiendo. Tiempo total estimado: **~15–20 minutos** (la mayor parte es CI
esperando aprobación + creación de stacks). Para el detalle de arquitectura,
decisiones de diseño, costos y el roadmap de HTTPS, ver [README.md](README.md).

## 1. Antes de empezar

| Necesitás | Para qué |
|---|---|
| Cuenta de AWS con acceso a consola en **us-east-1** (perfil admin) | Bootstrap manual (pasos 1-2) |
| Repo **`dev-assistant-infra`** (este) en GitHub | CI de infra |
| Repo **`dev-assistant-backend`** en GitHub | CI del backend, imagen de la app |
| Docker instalado localmente | Subir la imagen placeholder (paso 2) |
| AWS CLI configurado (opcional) | Solo si preferís `scripts/cfn.sh` en vez de la consola |

No hace falta AWS CLI para nada obligatorio: los pasos manuales se pueden hacer
100% por consola web, y el CI corre `scripts/cfn.sh` por su cuenta.

## 2. Mapa de fases

| Fase | Qué se despliega | ¿Quién lo hace? |
|---|---|---|
| 1. Bootstrap | `bootstrap` (OIDC + roles), `ecr` + imagen placeholder | Vos, a mano (una sola vez) |
| 2. Infra | `network → security → rds → ecs-cluster → alb → observability → backend-service` | CI de este repo, tras push a `main` |
| 3. App | Imagen real del backend en ECR + rollout del servicio ECS | CI de `dev-assistant-backend` |

## 3. Paso a paso

### Paso 1 — Bootstrap: OIDC + roles (consola, una sola vez)

1. AWS Console → **CloudFormation → Create stack → With new resources**.
2. **Upload a template file** → `templates/bootstrap/github-oidc.yml`.
3. Nombre de stack: `dev-assistant-github-oidc`.
4. Marcá el checkbox de capacidad **IAM con nombres personalizados** (`CAPABILITY_NAMED_IAM`).
5. Create stack → esperá `CREATE_COMPLETE`.
6. Pestaña **Outputs** → copiá y guardá:

| Output | Para qué se usa |
|---|---|
| `InfraDeployRoleArn` | Secret `AWS_DEPLOY_ROLE_ARN` en este repo (paso 3) |
| `DeployRoleArn` | Secret `AWS_ROLE_ARN` en `dev-assistant-backend` (paso 6) |

> Si este stack ya existía de una versión anterior (sin el stack `rds`), actualizalo
> primero (**Update stack → Replace current template**) antes del paso 4:
> `InfraDeployRole` necesita los permisos `rds:*` y `ssm:PutParameter`.

### Paso 2 — Bootstrap: ECR + imagen placeholder (consola/CLI, una sola vez)

Por consola, igual que el paso 1 (template `templates/bootstrap/ecr.yml`, stack
`dev-assistant-ecr`, sin capacidades especiales), o por CLI:

```bash
bash scripts/cfn.sh deploy ecr
```

Después, subí la imagen placeholder (necesita Docker):

```bash
bash scripts/push-placeholder.sh
```

Esto construye y sube (tag `:latest`) una imagen mínima que responde
`200 {"status":"ok"}` en `/health`, para que `backend-service` arranque con
`DesiredCount: 1` desde su primer deploy (paso 4) sin depender de que el CI del
backend haya corrido antes.

### Paso 3 — Configurar este repo en GitHub

**Settings → Secrets and variables → Actions** del repo `dev-assistant-infra`:

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | `InfraDeployRoleArn` del paso 1 |
| Secret | `RDS_MASTER_PASSWORD` | Contraseña fuerte, elegida por vos (nunca en `params/*.json` ni en git) |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `PROJECT_NAME` | `dev-assistant` |

Además, en **Settings → Environments**, creá el entorno `production` y agregá
*Required reviewers* (gate de aprobación antes de cada deploy).

### Paso 4 — Push a `main`: el CI despliega la infra

```bash
git push origin main
```

El workflow [`deploy-infra.yml`](.github/workflows/deploy-infra.yml), tras la
aprobación del Environment `production`, despliega en orden:

```
network → security → rds → ecs-cluster → alb → observability → backend-service
```

Justo después de `rds`, el paso automático `set-database-url` arma `DATABASE_URL`
(endpoint de RDS + `RDS_MASTER_PASSWORD`) y lo publica en SSM
(`/dev-assistant/DATABASE_URL`) — sin pasos manuales.

Si querés alarmas por email, completá `AlarmEmail` en `params/observability.json`
antes de este push (o después, con un redeploy del stack `observability`) y
confirmá el mail de suscripción que manda SNS.

Al terminar, el servicio ECS queda con **1 tarea corriendo la imagen placeholder**,
sana detrás del ALB.

### Paso 5 — Secretos manuales en SSM Parameter Store

`DATABASE_URL` ya quedó creado por el CI en el paso anterior. Faltan estos 3, a
mano, una sola vez:

1. Consola AWS → **Systems Manager → Parameter Store → Create parameter**.
2. Repetí para cada fila:

| Name | Tier | Type | KMS key source | Value |
|---|---|---|---|---|
| `/dev-assistant/ANTHROPIC_API_KEY` | Standard | SecureString | `alias/aws/ssm` (default) | tu API key de Anthropic |
| `/dev-assistant/OPENAI_API_KEY` | Standard | SecureString | `alias/aws/ssm` (default) | tu API key de OpenAI |
| `/dev-assistant/JWT_SECRET` | Standard | SecureString | `alias/aws/ssm` (default) | string aleatorio largo |

El rol de ejecución de ECS ya tiene permiso de lectura sobre `/dev-assistant/*`,
así que no hace falta tocar IAM.

### Paso 6 — Configurar el repo del backend en GitHub

**Settings → Secrets and variables → Actions** del repo `dev-assistant-backend`:

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | `DeployRoleArn` del paso 1 |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `ECR_REPOSITORY` | `dev-assistant-backend` |
| Variable | `ECS_CLUSTER` | `dev-assistant` |
| Variable | `ECS_SERVICE` | `dev-assistant-backend` |
| Variable | `ECS_TASK_FAMILY` | `dev-assistant-backend` |
| Variable | `CONTAINER_NAME` | `app` |

### Paso 7 — Primer deploy real del backend

El CI/CD de `dev-assistant-backend` construye la imagen real, la publica en ECR
(reemplazando el placeholder en el mismo tag `:latest`) y actualiza la tarea del
servicio. A partir de acá la API responde en `http://<AlbDnsName>` (output del
stack `alb`).

## 4. Referencia rápida — `scripts/cfn.sh`

### Variables de entorno

| Variable | Default | Obligatoria para |
|---|---|---|
| `AWS_REGION` | `us-east-1` | — |
| `PROJECT_NAME` | `dev-assistant` | — |
| `RDS_MASTER_PASSWORD` | *(sin default)* | `deploy rds`, `set-database-url` |

### Comandos

| Comando | Qué hace |
|---|---|
| `validate` | `cfn validate-template` de los 8 templates |
| `changeset <slug>` | Crea, muestra y borra un change set (preview, no cambia nada) |
| `deploy <slug>` | Despliega el stack (idempotente) |
| `destroy <slug>` | Borra el stack (si es `ecr`, vacía el repo antes; si es `rds`, deja snapshot final) |
| `destroy-all` | Borra los 7 stacks CI-managed en orden inverso |
| `set-database-url` | Publica `DATABASE_URL` en SSM a partir del output de `rds` |

### Slugs → template → stack

| Slug | Template | Stack | Capabilities |
|---|---|---|---|
| `bootstrap` | `templates/bootstrap/github-oidc.yml` | `dev-assistant-github-oidc` | `CAPABILITY_NAMED_IAM` |
| `ecr` | `templates/bootstrap/ecr.yml` | `dev-assistant-ecr` | — |
| `network` | `templates/infra/network.yaml` | `dev-assistant-network` | — |
| `security` | `templates/infra/security.yml` | `dev-assistant-security` | — |
| `rds` | `templates/infra/rds.yml` | `dev-assistant-rds` | — |
| `ecs-cluster` | `templates/infra/ecs-cluster.yml` | `dev-assistant-ecs-cluster` | `CAPABILITY_NAMED_IAM` |
| `alb` | `templates/infra/alb.yml` | `dev-assistant-alb` | — |
| `observability` | `templates/infra/observability.yml` | `dev-assistant-observability` | — |
| `backend-service` | `templates/app/backend-service.yml` | `dev-assistant-backend-service` | `CAPABILITY_NAMED_IAM` |

## 5. Verificación end-to-end

- [ ] **Stacks**: en CloudFormation, `bootstrap`, `ecr`, `network`, `security`,
      `rds`, `ecs-cluster`, `alb`, `observability` y `backend-service` en
      `CREATE_COMPLETE` / `UPDATE_COMPLETE`.
- [ ] **Salud**: `curl http://<AlbDnsName>/health` → `{"status":"ok"}` (usá el
      output `AlbDnsName` del stack `alb`).
- [ ] **Logs**: CloudWatch → `/ecs/dev-assistant-backend` — migraciones aplicadas,
      luego `DevAssistant API escuchando...` sin errores de TypeORM.
- [ ] **App**: probar registro/login (JWT) y el chat (conexión WebSocket).
- [ ] **CI/CD del backend**: un push a `main` en `dev-assistant-backend` construye,
      publica en ECR y deja el servicio `stable` con la nueva imagen.
- [ ] **Observability**: abrir el output `DashboardUrl` del stack `observability`
      y confirmar datos en los widgets del ALB; alarmas en `OK`
      (CloudWatch → Alarms, prefijo `dev-assistant-`).

## 6. Borrar todo (teardown)

```bash
bash scripts/cfn.sh destroy-all
```

Borra los 7 stacks CI-managed en orden inverso al deploy
(`backend-service → observability → alb → ecs-cluster → rds → security → network`).
No requiere `RDS_MASTER_PASSWORD` (usa `delete-stack`, sin parámetros).

Después, a mano si querés:

1. **Snapshot de RDS**: el borrado del stack `rds` deja un snapshot final
   (`DeletionPolicy: Snapshot`). Si no querés seguir pagando su almacenamiento,
   borralo desde **RDS → Snapshots**.
2. **Stack `ecr`**: `bash scripts/cfn.sh destroy ecr` (vacía el repo antes de
   borrarlo; `delete-stack` solo, sin vaciar, falla).
3. **Stack `bootstrap`**: `aws cloudformation delete-stack --stack-name dev-assistant-github-oidc`.
   Se puede borrar en cualquier momento — no lo usa ningún otro stack por
   `Fn::ImportValue`.

---

Para arquitectura, costos estimados, roadmap de HTTPS y el razonamiento detrás de
cada stack, ver [README.md](README.md).
