# dev-assistant-infra

Infraestructura como código (CloudFormation) para **dev-assistant-backend**: una API
NestJS con PostgreSQL + pgvector y WebSockets. Optimizada como **MVP** y desplegada en
**us-east-1**.

> Este repositorio contiene **solo la infraestructura**, con su **propio CI/CD**. El
> código de la aplicación, su `Dockerfile` y el workflow que la construye y publica la
> imagen viven en el repositorio `dev-assistant-backend`.

## Arquitectura

```
Internet ──HTTP:80──> ALB (público) ──HTTP:3000──> ECS Fargate (subred pública, IP pública)
                                                          │ (egress directo por IGW, sin NAT)
                                                          └──5432──> RDS PostgreSQL 16 (red propia, externa al stack)
```

- **Hoy la API se expone por HTTP.** HTTPS con dominio personalizado está planificado
  (ver [Roadmap: HTTPS + dominio](#roadmap-https--dominio-personalizado)).
- **Fargate en subredes públicas con IP pública** → evita el costo de un NAT Gateway
  (~US$32/mes). El Security Group de la app solo acepta tráfico del ALB en el 3000.
- **RDS** no es público: se accede solo desde el SG de la app. **Se crea por consola con
  su propia red** (DB subnet group + security group manuales) y **no forma parte de
  ningún stack**.
- **WebSockets** de socket.io funcionan de forma nativa sobre el ALB, con _stickiness_
  para el _fallback_ de long-polling.
- **Secretos**: las 4 variables sensibles (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `JWT_SECRET`, `DATABASE_URL`) viven en **SSM Parameter Store** (SecureString, gratis).
  No se usa Secrets Manager.

## Stacks (4 capas)

Se enlazan con `Export` / `ImportValue`. **RDS no es un stack.** El CI/CD del **infra** y
el del **backend** están separados en dos stacks: `00-cicd-infra` (bootstrap **manual por
consola**) y `02-cicd-backend` (lo gestiona el CI).

| Plantilla | Stack | Despliega | Qué crea |
|-----------|-------|-----------|----------|
| `templates/00-cicd-infra.yaml` | `dev-assistant-cicd-infra` | **Manual (consola)** | Proveedor **OIDC** de GitHub (único por cuenta) y el **`InfraDeployRole`** que asume el CI de infra. Exporta `OidcProviderArn`. |
| `templates/01-network.yaml` | `dev-assistant-network` | CI | VPC `10.20.0.0/16`, 2 subredes públicas (2 AZ), Internet Gateway, rutas y 2 Security Groups (`alb-sg`, `app-sg`). |
| `templates/02-cicd-backend.yaml` | `dev-assistant-cicd-backend` | CI | Repositorio **ECR** y el **`DeployRole`** que asume el CI del backend para publicar imágenes y desplegar en ECS. Importa `OidcProviderArn`. |
| `templates/03-service.yaml` | `dev-assistant-service` | CI | **ALB** (HTTP + WS), **cluster ECS**, **task definition**, **servicio Fargate**, roles de ejecución/tarea y log group. |

### Notas por stack

- **00-cicd-infra** (bootstrap manual): crea el **proveedor OIDC** de GitHub y el
  `InfraDeployRole`, que confía en `repo:<org>/dev-assistant-infra:*`. Se despliega **a
  mano por la consola** una sola vez, porque define el propio rol que usa el CI. El
  proveedor OIDC es **único por cuenta**: este stack asume que la cuenta aún no tiene uno
  de GitHub.
- **01-network**: la decisión de costo está aquí — Fargate vive en subredes **públicas**
  (`MapPublicIpOnLaunch`) y sale a Internet por el IGW, evitando el NAT Gateway. `app-sg`
  solo deja entrar al ALB. El RDS **no** está aquí (trae su propia red, ver
  [Crear RDS](#paso-por-consola--crear-rds-postgresql)).
- **02-cicd-backend**: el `DeployRole` confía en `repo:<org>/dev-assistant-backend:*` y
  solo puede empujar a su ECR y actualizar el servicio ECS. **Importa** el proveedor OIDC
  del stack `cicd-infra` (no lo recrea).
- **03-service**: la tarea corre con `assignPublicIp: ENABLED`,
  `enableExecuteCommand: true` (depuración con ECS Exec) y _circuit breaker_ con rollback.
  Lee los 4 secretos desde SSM `/dev-assistant/*`. **`DesiredCount` arranca en 0** a
  propósito: no hay imagen en ECR hasta que el CI/CD del backend publica la primera, y es
  ese CI/CD el que activa las tareas.

## Configuración (parámetros)

Los parámetros de cada stack se definen con **valores por defecto en las plantillas** y se
sobrescriben desde `params/*.json` solo cuando difieren o identifican el entorno
(`ProjectName`, `GitHubOrg`, `EcrRepositoryName`, `DomainName`, `AnthropicModel`, …). El CI
los aplica con `scripts/cfn.sh`; lo que no esté en el JSON usa el `Default` de la
plantilla. **No hay parámetros de tipo `AWS::SSM::Parameter::Value`**: los valores de
cuenta/entorno viven en `params/*.json`.

> `DomainName` (en `params/03-service.json`) es **cosmético** mientras la API sea HTTP: se
> usará al activar HTTPS. Hoy la API se alcanza por el **DNS del ALB** (output `AlbDnsName`).

## Requisitos previos

- Una **cuenta de AWS** con acceso a la consola web en **us-east-1** (perfil admin para el
  bootstrap manual). No necesitas AWS CLI: las operaciones manuales son por consola y el
  CI ejecuta `scripts/cfn.sh` por su cuenta.
- El repositorio **`dev-assistant-backend`** en GitHub (para el OIDC y su CI/CD).
- **Este repositorio (`dev-assistant-infra`)** en GitHub: su CI/CD asume el
  `InfraDeployRole`, cuya confianza OIDC está ligada a `repo:<org>/dev-assistant-infra:*`.

## Puesta en marcha (una sola vez)

1. **Bootstrap del CI de infra (consola).** En la consola de AWS →
   **CloudFormation → Create stack → With new resources** → **Upload a template file** →
   sube `templates/00-cicd-infra.yaml`. Nombre de stack `dev-assistant-cicd-infra`,
   reconoce la capacidad **IAM con nombres personalizados** (NAMED_IAM) y crea el stack.
   En la pestaña **Outputs** copia `InfraDeployRoleArn`.

2. **Configura este repositorio en GitHub** (Settings → Secrets and variables → Actions):
   - **Secret** `AWS_DEPLOY_ROLE_ARN` = `InfraDeployRoleArn` del paso 1.
   - **Variables**: `AWS_REGION` = `us-east-1`, `PROJECT_NAME` = `dev-assistant`.
   - En **Settings → Environments** crea `production` y añade _Required reviewers_ (gate de
     aprobación antes de cada deploy).

3. **Sube el repo y deja que el CI despliegue.** Con la rama `main` en GitHub, el push
   dispara el workflow: tras la aprobación del Environment `production`, despliega
   `network → cicd-backend → service`. El servicio queda con **0 tareas** (aún sin imagen).

4. **Crea el RDS por consola** (ver [Crear RDS](#paso-por-consola--crear-rds-postgresql))
   con su propia red. Copia su **Endpoint**.

5. **Crea los 4 secretos en SSM por consola** (ver
   [Secretos en SSM](#paso-por-consola--secretos-en-ssm-parameter-store)), incluido
   `/dev-assistant/DATABASE_URL` con el endpoint del RDS.

6. **Configura el repositorio del backend en GitHub** (ver
   [Variables y secretos del backend](#variables-y-secretos-de-github-backend)) con el
   output `DeployRoleArn` del stack `cicd-backend` y los outputs del `service`.

7. **Primer despliegue del backend.** El CI/CD del backend construye la imagen, la publica
   en ECR y **activa la tarea** del servicio. A partir de aquí la API responde por
   `http://<AlbDnsName>` (output del stack `service`).

## Paso por consola — Crear RDS PostgreSQL

RDS **no** está en CloudFormation; se crea a mano con su **propia red**. Reutiliza la VPC
del stack `01` (`dev-assistant-vpc`), pero el subnet group y el security group del RDS se
crean **manualmente** (no salen de ningún stack).

1. **EC2 → Security Groups → Create security group**: nombre `dev-assistant-rds-sg`, VPC
   `dev-assistant-vpc`. Una regla **inbound**: tipo **PostgreSQL** (TCP 5432) con
   **Source = el SG de la app** (`dev-assistant-app-sg`, el del output `AppSecurityGroupId`
   del stack `01`). Sin otras reglas.
2. **RDS → Subnet groups → Create DB subnet group**: nombre `dev-assistant-db-subnets`,
   VPC `dev-assistant-vpc`, con subredes en **2 AZ**. Para el MVP usa las **2 subredes
   públicas** del stack (`dev-assistant-public-1`, `dev-assistant-public-2`) y deja
   **Public access = No** (el acceso lo restringe el SG, no la subred).
3. **RDS → Databases → Create database** → **Standard create**:
   - Engine **PostgreSQL** (16.x) · Template **Dev/Test**.
   - DB instance identifier `dev-assistant-postgres`.
   - **Master username** `devassistant` · **Credentials = Self managed** → define una
     contraseña y **anótala** (no uses "managed in Secrets Manager", así puedes componer el
     `DATABASE_URL`).
   - Instance class **db.t4g.micro** · Storage **gp3 20 GB** (sin autoscaling) · **Single-AZ**.
   - Connectivity: VPC `dev-assistant-vpc` · DB subnet group `dev-assistant-db-subnets` ·
     **Public access = No** · **Existing VPC security group → `dev-assistant-rds-sg`**
     (quita el `default`).
   - Additional configuration: **Initial database name** `devassistant` · Backups 7 días ·
     **Performance Insights = off** · **Enhanced monitoring = off**.
4. **Create database** → espera a **Available** → copia el **Endpoint**.

> La app conecta con el **usuario master** a propósito: LangChain necesita ese privilegio
> para crear la extensión `vector` (pgvector) en el primer uso del RAG.

## Paso por consola — Secretos en SSM Parameter Store

La app necesita 4 secretos que **no** van en CloudFormation. Créalos en la consola web,
una sola vez:

1. Consola AWS → **Systems Manager → Parameter Store → Create parameter**.
2. Crea uno por cada **Name**:
   - `/dev-assistant/ANTHROPIC_API_KEY`
   - `/dev-assistant/OPENAI_API_KEY`
   - `/dev-assistant/JWT_SECRET` (valor largo y aleatorio)
   - `/dev-assistant/DATABASE_URL` =
     `postgresql://devassistant:<password>@<endpoint-rds>:5432/devassistant`
3. En cada uno: **Tier** = Standard · **Type** = **SecureString** · **KMS key source** =
   _My current account_ con `alias/aws/ssm` (default) · pega el valor en **Value** →
   **Create parameter**.

> El rol de ejecución de ECS ya tiene permiso de lectura sobre `/dev-assistant/*`, que
> cubre los 4 secretos.

## Variables y secretos de GitHub (backend)

En **Settings → Secrets and variables → Actions** del repo `dev-assistant-backend`:

- **Secret** `AWS_ROLE_ARN` = output `DeployRoleArn` del stack `cicd-backend`.
- **Variables** (Repository variables):

  | Variable | Valor |
  |---|---|
  | `AWS_REGION` | `us-east-1` |
  | `ECR_REPOSITORY` | `dev-assistant-backend` |
  | `ECS_CLUSTER` | `dev-assistant` |
  | `ECS_SERVICE` | `dev-assistant-backend` |
  | `ECS_TASK_FAMILY` | `dev-assistant-backend` |
  | `CONTAINER_NAME` | `app` |

  (Los valores coinciden con los outputs del stack `service`.)

## CI/CD de la infraestructura

El workflow [`.github/workflows/deploy-infra.yml`](.github/workflows/deploy-infra.yml)
valida y despliega los stacks con GitHub Actions + OIDC (sin llaves estáticas). El camino
normal es por **Pull Request**.

- **En cada PR**: `cfn-lint` (sintaxis), `checkov` (seguridad, en _soft-fail_),
  `validate-template`, y un **plan** que crea _change sets_ para previsualizar el diff de
  cada stack y lo publica como comentario del PR. **No cambia nada.**
- **En push a `main`** (o `workflow_dispatch`): despliega en orden
  `network → cicd-backend → service` tras la **aprobación manual** del Environment
  `production`. Idempotente (`--no-fail-on-empty-changeset`).

> El stack `00-cicd-infra` **no lo gestiona el CI** (define el propio `InfraDeployRole` que
> el CI asume): se valida en cada PR pero solo se despliega **a mano por la consola**.

> La imagen se mantiene en `:latest` (constante), así que redeployar la infra **no
> revierte** la imagen: el rollout real por SHA lo maneja el workflow del backend. El CI
> de infra **no** crea RDS ni los secretos de SSM (son manuales por diseño).

La lógica de despliegue vive en [`scripts/cfn.sh`](scripts/cfn.sh)
(`validate` | `changeset <slug>` | `deploy <slug>`), que el workflow ejecuta
internamente; pasa los params de `params/*.json`.

## Roadmap: HTTPS + dominio personalizado

Hoy el ALB expone **HTTP:80**. Para servir la API por **HTTPS** en un dominio propio
(p. ej. `api.tudominio.com`):

1. **Certificado ACM** en us-east-1 para el dominio (validación por DNS). Si gestionas el
   dominio en **Route53**, la validación es automática; si no, añade el CNAME de
   validación en tu DNS.
2. En [`templates/03-service.yaml`](templates/03-service.yaml): **descomenta** el bloque
   `HttpsListener` (443, con el `CertificateArn`) y cambia el `HttpListener` (80) de
   `forward` a **redirect 80 → 443** (el bloque ya está como comentario).
3. El Security Group del ALB **ya tiene abierto el 443** (reservado en `01-network.yaml`).
4. Pon el dominio real en `params/03-service.json` (`DomainName`) y despliega por PR.
5. **Apunta el dominio al ALB**: crea un registro **alias A** de `api.tudominio.com` → el
   `AlbDnsName` del output del stack `service` (en Route53, o un CNAME equivalente en tu
   DNS).

## Estimación de costos (us-east-1, ~mensual)

| Recurso | Aprox. |
|---|---|
| Fargate 0.5 vCPU / 1 GB 24/7 (cuando hay tareas activas) | ~US$18 |
| ALB | ~US$16 + LCU |
| RDS db.t4g.micro single-AZ + 20 GB gp3 | ~US$15 |
| SSM Parameter Store (Standard) | gratis |
| CloudWatch Logs + ECR storage | ~US$1–3 |
| **Total** | **~US$50–55** |

> Con `DesiredCount: 0` y sin imagen, el costo de Fargate es **US$0** hasta que el CI/CD
> del backend activa la tarea.

**Palancas de ahorro** (no activadas): `FARGATE_SPOT` (~70% menos cómputo, con riesgo de
interrupción), apagar la tarea de noche con scheduled scaling, o reemplazar el ALB por una
tarea pública directa (se pierde el WS gestionado).

## Verificación end-to-end

1. **Stacks OK**: en la consola de **CloudFormation**, los stacks `network`,
   `cicd-backend` y `service` en `CREATE_COMPLETE` / `UPDATE_COMPLETE`.
2. **Salud**: `curl http://<AlbDnsName>/health` → `{"status":"ok"}` (valida ALB + tarea
   sana). Usa el output `AlbDnsName` del stack `service`.
3. **Logs**: CloudWatch → `/ecs/dev-assistant-backend`. Debe verse que las **migraciones
   se aplicaron** y luego `DevAssistant API escuchando...` sin errores de TypeORM.
4. **App**: probar registro/login (JWT) y el chat (incluida la conexión WebSocket).
5. **CI/CD**: un push a `main` del repo backend debe construir, publicar en ECR y dejar el
   servicio `stable` con la nueva imagen.

> La subida de documentos (S3), la ingesta asíncrona (SQS) y el PDF de stats (Lambda) están
> **fuera de esta fase**: el Task Role aún no tiene esos permisos.

## Notas

- **pgvector** no requiere pasos manuales: la extensión `vector` y la tabla `chunks` las
  crea LangChain (`PGVectorStore`) en el primer uso del RAG, con las credenciales master de
  RDS.
- **Para borrar todo**: elimina **primero a mano** el RDS y su red propia (la instancia
  `dev-assistant-postgres` —con snapshot final si quieres conservar los datos—, luego el DB
  subnet group `dev-assistant-db-subnets` y el security group `dev-assistant-rds-sg`).
  Después borra los stacks en orden inverso (`service → cicd-backend → network →
  cicd-infra`). Borra `cicd-infra` **al final**: `cicd-backend` importa su export
  `OidcProviderArn` y CloudFormation no permite eliminar un stack mientras otro consume su
  export.
