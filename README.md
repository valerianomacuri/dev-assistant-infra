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

## Stacks (8 capas)

Se enlazan con `Export` / `ImportValue`. **RDS no es un stack.** El único stack manual es
`bootstrap` (`templates/bootstrap/github-oidc.yml`): crea el proveedor OIDC de GitHub y
**los dos roles** que asumen el CI de infra y el CI del backend (ya no están en stacks
separados). Los otros 7 los gestiona el CI, en este orden de dependencias:
`network → security → ecr → ecs-cluster → alb → observability → backend-service`.

| Plantilla | Stack | Despliega | Qué crea |
|-----------|-------|-----------|----------|
| `templates/bootstrap/github-oidc.yml` | `dev-assistant-cicd-infra` | **Manual (consola)** | Proveedor **OIDC** de GitHub (único por cuenta), el **`InfraDeployRole`** que asume el CI de infra y el **`DeployRole`** que asume el CI del backend. |
| `templates/infra/network.yaml` | `dev-assistant-network` | CI | VPC `10.20.0.0/16`, 2 subredes públicas (2 AZ), Internet Gateway y rutas. Exporta `VpcId`, `PublicSubnet1`, `PublicSubnet2`. |
| `templates/infra/security.yml` | `dev-assistant-security` | CI | Security Groups `alb-sg` y `app-sg`. Importa `VpcId`. Exporta `AlbSecurityGroupId`, `AppSecurityGroupId`. |
| `templates/infra/ecr.yml` | `dev-assistant-ecr` | CI | Repositorio **ECR** de la imagen del backend. |
| `templates/infra/ecs-cluster.yml` | `dev-assistant-ecs-cluster` | CI | **Cluster ECS**, log group de CloudWatch y el rol de ejecución de la tarea. Exporta `ClusterName`, `BackendLogGroupName`, `ExecutionRoleArn`. |
| `templates/infra/alb.yml` | `dev-assistant-alb` | CI | **ALB** (HTTP + WS) y su Target Group. Importa `AlbSecurityGroupId`, `PublicSubnet1/2`, `VpcId`. Exporta `AlbDnsName`, `TargetGroupArn`, `LoadBalancerFullName`, `TargetGroupFullName`. |
| `templates/infra/observability.yml` | `dev-assistant-observability` | CI | **Tópico SNS** de alarmas (con suscripción por email opcional), **alarmas CloudWatch** de CPU/memoria del servicio ECS, hosts no saludables/5XX/latencia del ALB y errores en el log del backend, y un **dashboard** único. Importa `ClusterName`, `BackendLogGroupName`, `LoadBalancerFullName`, `TargetGroupFullName`. Exporta `AlarmTopicArn`. |
| `templates/app/backend-service.yml` | `dev-assistant-backend-service` | CI | Rol de tarea, **task definition** y **servicio Fargate**. Importa el cluster, el rol de ejecución/log group, las subredes, `app-sg` y el Target Group. |

### Notas por stack

- **bootstrap** (manual): crea el **proveedor OIDC** de GitHub, el `InfraDeployRole`
  (confía en `repo:<org>/dev-assistant-infra:*`) y el `DeployRole` (confía en
  `repo:<org>/dev-assistant-backend:*`, solo puede empujar a su ECR y actualizar el
  servicio ECS). Se despliega **a mano por la consola** una sola vez, porque define los
  propios roles que usa el CI — incluidos cambios futuros a `DeployRole`, que también van
  a mano. El proveedor OIDC es **único por cuenta**: este stack asume que la cuenta aún no
  tiene uno de GitHub.
- **network**: la decisión de costo está aquí — Fargate vive en subredes **públicas**
  (`MapPublicIpOnLaunch`) y sale a Internet por el IGW, evitando el NAT Gateway. El RDS
  **no** está aquí (trae su propia red, ver
  [Crear RDS](#paso-por-consola--crear-rds-postgresql)).
- **security**: `app-sg` solo deja entrar al ALB (puerto 3000); depende del `VpcId` que
  exporta `network`.
- **ecs-cluster** / **alb** / **backend-service**: la tarea corre con
  `assignPublicIp: ENABLED`, `enableExecuteCommand: true` (depuración con ECS Exec) y
  _circuit breaker_ con rollback. Lee los 4 secretos desde SSM `/dev-assistant/*`.
  **`DesiredCount` arranca en 0** a propósito: no hay imagen en ECR hasta que el CI/CD del
  backend publica la primera, y es ese CI/CD el que activa las tareas.
- **observability**: cubre ECS + ALB + logs; **RDS queda fuera** porque no es un stack
  (se crea a mano, ver [Crear RDS](#paso-por-consola--crear-rds-postgresql)). El parámetro
  `AlarmEmail` (en `params/observability.json`) está vacío por defecto — sin él no se crea
  la suscripción SNS y las alarmas no notifican a nadie. Al completarlo y desplegar, AWS
  manda un mail de confirmación al endpoint que **hay que confirmar a mano** (si no, SNS
  descarta las notificaciones). Con `DesiredCount: 0` es normal ver los widgets de ECS del
  dashboard sin datos hasta que el backend activa la primera tarea.

## Configuración (parámetros)

Los parámetros de cada stack se definen con **valores por defecto en las plantillas** y se
sobrescriben desde `params/*.json` solo cuando difieren o identifican el entorno
(`ProjectName`, `GitHubOrg`, `EcrRepositoryName`, `DomainName`, `AnthropicModel`, …). El CI
los aplica con `scripts/cfn.sh`; lo que no esté en el JSON usa el `Default` de la
plantilla. **No hay parámetros de tipo `AWS::SSM::Parameter::Value`**: los valores de
cuenta/entorno viven en `params/*.json`.

> `DomainName` (en `params/alb.json`) es **cosmético** mientras la API sea HTTP: se
> usará al activar HTTPS. Hoy la API se alcanza por el **DNS del ALB** (output `AlbDnsName`).

## Requisitos previos

- Una **cuenta de AWS** con acceso a la consola web en **us-east-1** (perfil admin para el
  bootstrap manual). No necesitas AWS CLI: las operaciones manuales son por consola y el
  CI ejecuta `scripts/cfn.sh` por su cuenta.
- El repositorio **`dev-assistant-backend`** en GitHub (para el OIDC y su CI/CD).
- **Este repositorio (`dev-assistant-infra`)** en GitHub: su CI/CD asume el
  `InfraDeployRole`, cuya confianza OIDC está ligada a `repo:<org>/dev-assistant-infra:*`.

## Puesta en marcha (una sola vez)

1. **Bootstrap del CI de infra y del backend (consola).** En la consola de AWS →
   **CloudFormation → Create stack → With new resources** → **Upload a template file** →
   sube `templates/bootstrap/github-oidc.yml`. Nombre de stack `dev-assistant-cicd-infra`,
   reconoce la capacidad **IAM con nombres personalizados** (NAMED_IAM) y crea el stack.
   En la pestaña **Outputs** copia `InfraDeployRoleArn` y `DeployRoleArn`.

2. **Configura este repositorio en GitHub** (Settings → Secrets and variables → Actions):
   - **Secret** `AWS_DEPLOY_ROLE_ARN` = `InfraDeployRoleArn` del paso 1.
   - **Variables**: `AWS_REGION` = `us-east-1`, `PROJECT_NAME` = `dev-assistant`.
   - En **Settings → Environments** crea `production` y añade _Required reviewers_ (gate de
     aprobación antes de cada deploy).

3. **Sube el repo y deja que el CI despliegue.** Con la rama `main` en GitHub, el push
   dispara el workflow: tras la aprobación del Environment `production`, despliega
   `network → security → ecr → ecs-cluster → alb → observability → backend-service`. El
   servicio queda con **0 tareas** (aún sin imagen). Si querés recibir alarmas por email,
   completá `AlarmEmail` en `params/observability.json` antes de este paso (o después, con
   un redeploy del stack `observability`) y confirmá el mail que manda SNS.

4. **Crea el RDS por consola** (ver [Crear RDS](#paso-por-consola--crear-rds-postgresql))
   con su propia red. Copia su **Endpoint**.

5. **Crea los 4 secretos en SSM por consola** (ver
   [Secretos en SSM](#paso-por-consola--secretos-en-ssm-parameter-store)), incluido
   `/dev-assistant/DATABASE_URL` con el endpoint del RDS.

6. **Configura el repositorio del backend en GitHub** (ver
   [Variables y secretos del backend](#variables-y-secretos-de-github-backend)) con el
   output `DeployRoleArn` del paso 1 y los outputs de los stacks `ecs-cluster` y
   `backend-service`.

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

- **Secret** `AWS_ROLE_ARN` = output `DeployRoleArn` del stack `cicd-infra` (bootstrap).
- **Variables** (Repository variables):

  | Variable | Valor |
  |---|---|
  | `AWS_REGION` | `us-east-1` |
  | `ECR_REPOSITORY` | `dev-assistant-backend` |
  | `ECS_CLUSTER` | `dev-assistant` |
  | `ECS_SERVICE` | `dev-assistant-backend` |
  | `ECS_TASK_FAMILY` | `dev-assistant-backend` |
  | `CONTAINER_NAME` | `app` |

  (`ECS_CLUSTER` coincide con el output `ClusterName` del stack `ecs-cluster`;
  `ECS_SERVICE`, `ECS_TASK_FAMILY` y `CONTAINER_NAME` con los outputs del stack
  `backend-service`.)

## CI/CD de la infraestructura

El workflow [`.github/workflows/deploy-infra.yml`](.github/workflows/deploy-infra.yml)
valida y despliega los stacks con GitHub Actions + OIDC (sin llaves estáticas). El camino
normal es por **Pull Request**.

- **En cada PR**: `cfn-lint` (sintaxis), `checkov` (seguridad, en _soft-fail_),
  `validate-template`, y un **plan** que crea _change sets_ para previsualizar el diff de
  cada stack y lo publica como comentario del PR. **No cambia nada.**
- **En push a `main`** (o `workflow_dispatch`): despliega en orden
  `network → security → ecr → ecs-cluster → alb → backend-service` tras la **aprobación
  manual** del Environment `production`. Idempotente (`--no-fail-on-empty-changeset`).

> El stack `bootstrap` (`dev-assistant-cicd-infra`) **no lo gestiona el CI** (define los
> propios roles `InfraDeployRole`/`DeployRole` que el CI asume): se valida en cada PR pero
> solo se despliega **a mano por la consola**.

> La imagen se mantiene en `:latest` (constante), así que redeployar la infra **no
> revierte** la imagen: el rollout real por SHA lo maneja el workflow del backend. El CI
> de infra **no** crea RDS ni los secretos de SSM (son manuales por diseño).

La lógica de despliegue vive en [`scripts/cfn.sh`](scripts/cfn.sh)
(`validate` | `changeset <slug>` | `deploy <slug>`), que el workflow ejecuta
internamente; pasa los params de `params/*.json`.

`scripts/cfn.sh` también tiene `destroy <slug>` y `destroy-all` para borrar stacks. Son
solo para uso manual desde la terminal (con las credenciales AWS que ya tengas
configuradas) — el workflow **no** los ejecuta. Ver [Notas](#notas) para el borrado
completo del entorno.

## Roadmap: HTTPS + dominio personalizado

Hoy el ALB expone **HTTP:80**. Para servir la API por **HTTPS** en un dominio propio
(p. ej. `api.tudominio.com`):

1. **Certificado ACM** en us-east-1 para el dominio (validación por DNS). Si gestionas el
   dominio en **Route53**, la validación es automática; si no, añade el CNAME de
   validación en tu DNS.
2. En [`templates/infra/alb.yml`](templates/infra/alb.yml): **descomenta** el bloque
   `HttpsListener` (443, con el `CertificateArn`) y cambia el `HttpListener` (80) de
   `forward` a **redirect 80 → 443** (el bloque ya está como comentario).
3. El Security Group del ALB **ya tiene abierto el 443** (reservado en
   `templates/infra/security.yml`).
4. Pon el dominio real en `params/alb.json` (`DomainName`) y despliega por PR.
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
| CloudWatch Alarms (6) + SNS + Dashboard | ~US$0.60 (dashboard gratis: primeros 3 por cuenta) |
| **Total** | **~US$51–56** |

> Con `DesiredCount: 0` y sin imagen, el costo de Fargate es **US$0** hasta que el CI/CD
> del backend activa la tarea.

**Palancas de ahorro** (no activadas): `FARGATE_SPOT` (~70% menos cómputo, con riesgo de
interrupción), apagar la tarea de noche con scheduled scaling, o reemplazar el ALB por una
tarea pública directa (se pierde el WS gestionado).

## Verificación end-to-end

1. **Stacks OK**: en la consola de **CloudFormation**, los stacks `network`, `security`,
   `ecr`, `ecs-cluster`, `alb`, `observability` y `backend-service` en `CREATE_COMPLETE` /
   `UPDATE_COMPLETE`.
2. **Salud**: `curl http://<AlbDnsName>/health` → `{"status":"ok"}` (valida ALB + tarea
   sana). Usa el output `AlbDnsName` del stack `alb`.
3. **Logs**: CloudWatch → `/ecs/dev-assistant-backend`. Debe verse que las **migraciones
   se aplicaron** y luego `DevAssistant API escuchando...` sin errores de TypeORM.
4. **App**: probar registro/login (JWT) y el chat (incluida la conexión WebSocket).
5. **CI/CD**: un push a `main` del repo backend debe construir, publicar en ECR y dejar el
   servicio `stable` con la nueva imagen.
6. **Observability**: abrí el output `DashboardUrl` del stack `observability` y confirmá
   que los widgets de ALB (requests, hosts saludables) muestran datos. Las alarmas deberían
   estar en `OK` (o `INSUFFICIENT_DATA` si el servicio sigue en `DesiredCount: 0`), visibles
   en CloudWatch → Alarms con el prefijo `dev-assistant-`.

> La subida de documentos (S3), la ingesta asíncrona (SQS) y el PDF de stats (Lambda) están
> **fuera de esta fase**: el Task Role aún no tiene esos permisos.

## Notas

- **pgvector** no requiere pasos manuales: la extensión `vector` y la tabla `chunks` las
  crea LangChain (`PGVectorStore`) en el primer uso del RAG, con las credenciales master de
  RDS.
- **Para borrar todo**: elimina **primero a mano** el RDS y su red propia (la instancia
  `dev-assistant-postgres` —con snapshot final si quieres conservar los datos—, luego el DB
  subnet group `dev-assistant-db-subnets` y el security group `dev-assistant-rds-sg`).
  Después corré `bash scripts/cfn.sh destroy-all`: borra los 7 stacks CI-managed en orden
  inverso al de despliegue (`backend-service → observability → alb → ecs-cluster → ecr →
  security → network`), vaciando antes el repo ECR (si no, `delete-stack` falla con
  "repository not empty") y esperando a que cada borrado termine antes de seguir con el
  siguiente. No toca `cicd-infra` (bootstrap) a propósito, para no invalidar el rol OIDC
  mientras el CI todavía lo necesita. Ese stack se borra aparte, a mano
  (`aws cloudformation delete-stack --stack-name dev-assistant-cicd-infra`), y podés
  hacerlo en cualquier momento: al fusionar `InfraDeployRole` y `DeployRole` en el mismo
  template ya no queda ningún `Fn::ImportValue` de otro stack hacia su export
  `OidcProviderArn`.
