# dev-assistant-infra

Infraestructura como código (CloudFormation) para **dev-assistant-backend**, una
API NestJS con Postgres + pgvector y WebSockets. Optimizada para un **MVP en
Perú**, desplegada en **us-east-1**.

> Este repo contiene **solo la infraestructura**. El código de la app, su
> `Dockerfile` y el workflow de CI/CD viven en el repo `dev-assistant-backend`.

## Arquitectura

```
Internet ──HTTPS:443──> ALB (público) ──HTTP:3000──> ECS Fargate (1 tarea, subred pública, IP pública)
                                                              │ (egress directo por IGW, sin NAT)
                                                              └──5432──> RDS PostgreSQL 16 (subred privada)
```

- **Fargate en subredes públicas con IP pública** → evita el costo de un NAT
  Gateway. El Security Group de la app solo acepta tráfico del ALB en el 3000.
- **RDS** en subredes privadas, no público, solo accesible desde el SG de la app.
  **Se crea a mano por consola** (no está en CloudFormation), reutilizando la red
  del stack `01`.
- **HTTPS** terminado en el ALB (certificado ACM). WebSockets de socket.io
  funcionan de forma nativa sobre el ALB, con stickiness para el long-polling.
- **Secretos**: las 4 variables sensibles (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `JWT_SECRET`, `DATABASE_URL`) van en **SSM Parameter Store** (SecureString,
  gratis). No se usa Secrets Manager.

## Stacks (3 capas)

Se despliegan en orden; se enlazan con `Export`/`ImportValue`. **RDS no es un
stack** — se crea por consola (ver más abajo).

| # | Plantilla | Qué crea |
|---|-----------|----------|
| 1 | `templates/01-network.yaml` | VPC `10.20.0.0/16`, 2 subredes públicas + 2 privadas (2 AZ), Internet Gateway y rutas, y 3 Security Groups (`alb-sg`, `app-sg`, `rds-sg`) encadenados. |
| 2 | `templates/02-cicd.yaml` | Repositorio **ECR**, proveedor **OIDC** de GitHub y el **rol IAM** que asume GitHub Actions para publicar imágenes y desplegar en ECS. |
| 3 | `templates/03-service.yaml` | Certificado **ACM**, **ALB** (HTTP→HTTPS + WS), **cluster ECS**, **task definition**, **servicio Fargate**, roles de ejecución/tarea y log group. |

### Recursos clave por stack

- **01-network**: la decisión de costo está aquí — Fargate vive en las subredes
  **públicas** (`MapPublicIpOnLaunch`) y sale a Internet por el IGW, así no hace
  falta NAT Gateway (~US$32/mes). `app-sg` solo deja entrar al ALB; `rds-sg` solo
  deja entrar a `app-sg`. El `rds-sg` y las subredes privadas quedan listos para
  que el **RDS manual** los reutilice.
- **02-cicd**: el rol de deploy confía en `repo:<org>/<repo>:*` vía OIDC. Si la
  cuenta ya tiene el proveedor OIDC de GitHub, pon `CreateOIDCProvider=false` y
  pasa `ExistingOIDCProviderArn` (solo puede haber uno por cuenta).
- **03-service**: la tarea corre con `assignPublicIp: ENABLED`,
  `enableExecuteCommand: true` (para depurar con ECS Exec) y circuit breaker con
  rollback. Lee las 4 variables sensibles desde SSM `/dev-assistant/*`. Las
  migraciones de TypeORM se aplican solas al arrancar la tarea.

## Requisitos previos

- AWS CLI v2 configurado (`aws configure`) con un perfil admin en **us-east-1**.
- Un dominio para la API (p.ej. `api.tudominio.com`). Si está en **Route53**,
  apunta el `HostedZoneId` para validar el certificado automáticamente.
- El repo `dev-assistant-backend` en GitHub (para el OIDC y el CI/CD).

## Orden de despliegue

Edita primero los `params/*.json` (sobre todo `GitHubOrg`, `DomainName`,
`ImageUri`). Región **us-east-1** en todos los comandos.

```bash
# 1) Red
aws cloudformation deploy --region us-east-1 \
  --stack-name dev-assistant-network \
  --template-file templates/01-network.yaml \
  --parameter-overrides ProjectName=dev-assistant

# 2) CI/CD (ECR + OIDC + rol). Reemplaza TU_ORG.
aws cloudformation deploy --region us-east-1 \
  --stack-name dev-assistant-cicd \
  --capabilities CAPABILITY_NAMED_IAM \
  --template-file templates/02-cicd.yaml \
  --parameter-overrides ProjectName=dev-assistant GitHubOrg=TU_ORG GitHubRepo=dev-assistant-backend
```

Luego:

3. **Crea el RDS por consola** (ver _Crear RDS_ más abajo) reutilizando la red
   del stack `01`. Copia su **Endpoint**.
4. **Crea los 4 secretos en SSM** (ver _Secretos en SSM_), incluido
   `/dev-assistant/DATABASE_URL` con el endpoint del RDS.
5. **Configura los secrets/variables de GitHub** en el repo del backend
   (outputs del stack `cicd` + valores del `service`).
6. **Primer build de la imagen** (dispara el workflow o build manual) para que
   ECR tenga una imagen que la tarea pueda arrancar.
7. **Servicio** (necesita una `ImageUri` real ya en ECR):

```bash
aws cloudformation deploy --region us-east-1 \
  --stack-name dev-assistant-service \
  --capabilities CAPABILITY_NAMED_IAM \
  --template-file templates/03-service.yaml \
  --parameter-overrides ProjectName=dev-assistant \
    DomainName=api.tudominio.com \
    HostedZoneId=ZXXXXXXXXXXXX \
    ImageUri=<ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/dev-assistant-backend:<tag>
```

8. **Apunta el dominio al ALB**: crea un registro (alias A en Route53 o CNAME en
   tu DNS) de `api.tudominio.com` → el `AlbDnsName` del output del stack `service`.

> Outputs útiles: `aws cloudformation describe-stacks --stack-name dev-assistant-cicd --query "Stacks[0].Outputs"` (igual para `service`).

## Paso por consola — Crear RDS PostgreSQL

RDS **no** está en CloudFormation; se crea a mano, reutilizando la VPC, las
subredes privadas y el `dev-assistant-rds-sg` del stack `01`.

1. **RDS → Subnet groups → Create DB subnet group**: name
   `dev-assistant-db-subnets`, VPC `dev-assistant-vpc`, añade las 2 subredes
   **privadas** (`dev-assistant-private-1`, `dev-assistant-private-2`) en sus 2 AZ.
2. **RDS → Databases → Create database** → **Standard create**:
   - Engine **PostgreSQL** (16.x) · Template **Dev/Test**.
   - DB instance identifier `dev-assistant-postgres`.
   - **Master username** `devassistant` · **Credentials = Self managed** → define
     una contraseña y **anótala** (no uses "managed in Secrets Manager", así
     puedes componer el `DATABASE_URL`).
   - Instance class **db.t4g.micro** · Storage **gp3 20 GB** (sin autoscaling) ·
     **Single-AZ**.
   - Connectivity: VPC `dev-assistant-vpc` · DB subnet group
     `dev-assistant-db-subnets` · **Public access = No** · **Existing VPC security
     group → `dev-assistant-rds-sg`** (quita el `default`) · AZ: no preference.
   - Additional configuration: **Initial database name** `devassistant` · Backups
     7 días · **Performance Insights = off** · **Enhanced monitoring = off**.
3. **Create database** → espera a **Available** → copia el **Endpoint**.

La app conecta con el **usuario master** a propósito: LangChain necesita ese
privilegio para crear la extensión `vector` (pgvector) en el primer uso del RAG.

## Paso por consola — Crear los secretos en SSM Parameter Store

La app necesita 4 secretos que **no** van en CloudFormation (para no exponerlos).
Créalos en la consola web, una sola vez:

1. Consola AWS → **Systems Manager** → **Parameter Store** → **Create parameter**.
2. Repite para cada uno de estos **Name**:
   - `/dev-assistant/ANTHROPIC_API_KEY`
   - `/dev-assistant/OPENAI_API_KEY`
   - `/dev-assistant/JWT_SECRET`  (usa un valor largo y aleatorio)
   - `/dev-assistant/DATABASE_URL` =
     `postgresql://devassistant:<password>@<endpoint-rds>:5432/devassistant`
3. En cada uno: **Tier** = Standard · **Type** = **SecureString** · **KMS key
   source** = _My current account_ con la key `alias/aws/ssm` (default) · pega el
   valor real en **Value** → **Create parameter**.

El rol de ejecución de ECS ya tiene permiso de lectura sobre `/dev-assistant/*`,
que cubre los 4.

## Variables y secretos de GitHub (repo del backend)

En **Settings → Secrets and variables → Actions** del repo `dev-assistant-backend`:

- **Secret** `AWS_ROLE_ARN` = output `DeployRoleArn` del stack `cicd`.
- **Variables** (Repository variables):
  - `AWS_REGION` = `us-east-1`
  - `ECR_REPOSITORY` = `dev-assistant-backend`
  - `ECS_CLUSTER` = `dev-assistant`
  - `ECS_SERVICE` = `dev-assistant-backend`
  - `ECS_TASK_FAMILY` = `dev-assistant-backend`
  - `CONTAINER_NAME` = `app`

## Estimación de costos (us-east-1, ~mensual)

| Recurso | Aprox. |
|---|---|
| Fargate 0.5 vCPU / 1 GB 24/7 | ~US$18 |
| ALB | ~US$16 + LCU |
| RDS db.t4g.micro single-AZ + 20 GB gp3 | ~US$15 |
| SSM Parameter Store (SecureString Standard) | gratis |
| CloudWatch Logs + ECR storage | ~US$1-3 |
| **Total** | **~US$50-55** |

**Palancas de ahorro** (no activadas por defecto): usar `FARGATE_SPOT`
(~70% menos cómputo, con riesgo de interrupción), apagar la tarea de noche con
scheduled scaling, o reemplazar el ALB por una tarea pública directa (se pierde
HTTPS/WS gestionado).

## Verificación end-to-end (manual)

1. **Stacks OK**: `aws cloudformation describe-stacks --query "Stacks[].StackStatus"`
   → todos `CREATE_COMPLETE` / `UPDATE_COMPLETE`.
2. **Salud**: `curl https://api.tudominio.com/health` → `{"status":"ok"}`
   (valida ALB + certificado + tarea sana).
3. **Logs**: CloudWatch → `/ecs/dev-assistant-backend`. Debe verse que las
   **migraciones se aplicaron** y luego `DevAssistant API escuchando...` sin
   errores de TypeORM.
4. **App**: probar registro/login (JWT) y el chat (incluida la conexión
   WebSocket) contra `https://api.tudominio.com`.
5. **CI/CD**: un push a `main` del repo backend debe construir, publicar en ECR
   y dejar el servicio `stable` con la nueva imagen.

> La subida de documentos (S3), la ingesta asíncrona (SQS) y el PDF de stats
> (Lambda) están **fuera de esta fase**: el Task Role aún no tiene esos permisos.

## Notas

- **pgvector** no requiere ningún paso manual: la extensión `vector` y la tabla
  `chunks` las crea LangChain (`PGVectorStore`) en el primer uso del RAG, usando
  las credenciales master de RDS.
- Para borrar todo, elimina los stacks en orden inverso (`service` → `cicd` →
  `network`) y borra el **RDS a mano** desde la consola (con snapshot final si
  quieres conservar los datos).
