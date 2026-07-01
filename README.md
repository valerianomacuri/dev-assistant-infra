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
                                                          └──5432──> RDS PostgreSQL 16 (subred privada, mismo VPC)
```

- **Hoy la API se expone por HTTP.** HTTPS con dominio personalizado está planificado
  (ver [Roadmap: HTTPS + dominio](#roadmap-https--dominio-personalizado)).
- **Fargate en subredes públicas con IP pública** → evita el costo de un NAT Gateway
  (~US$32/mes). El Security Group de la app solo acepta tráfico del ALB en el 3000.
- **RDS** vive en **subredes privadas** dedicadas (sin ruta a Internet — no hace falta
  NAT porque RDS no necesita salida a Internet) y solo se accede desde el SG de la app.
  Es un stack más de CloudFormation (`rds`, ver [Stacks](#stacks-9-capas)): la instancia
  mantiene `DeletionPolicy`/`UpdateReplacePolicy: Snapshot`, así que un borrado o
  reemplazo siempre deja un snapshot final.
- **WebSockets** de socket.io funcionan de forma nativa sobre el ALB, con _stickiness_
  para el _fallback_ de long-polling.
- **Secretos**: las 4 variables sensibles (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `JWT_SECRET`, `DATABASE_URL`) viven en **SSM Parameter Store** (SecureString, gratis).
  No se usa Secrets Manager.

## Stacks (9 capas)

Se enlazan con `Export` / `ImportValue`. Hay dos stacks manuales: `bootstrap`
(`templates/bootstrap/github-oidc.yml`), que crea el proveedor OIDC de GitHub y **los dos
roles** que asumen el CI de infra y el CI del backend (ya no están en stacks separados), y
`ecr` (`templates/bootstrap/ecr.yml`), que crea el repositorio antes de que corra
cualquier CI para poder subirle una imagen **placeholder** (ver
[Puesta en marcha](#puesta-en-marcha-una-sola-vez)) y así arrancar `backend-service` con
tareas activas desde su primer deploy. Los otros 7 los gestiona el CI, en este orden de
dependencias: `network → security → rds → ecs-cluster → alb → observability →
backend-service`.

| Plantilla | Stack | Despliega | Qué crea |
|-----------|-------|-----------|----------|
| `templates/bootstrap/github-oidc.yml` | `dev-assistant-github-oidc` | **Manual (consola)** | Proveedor **OIDC** de GitHub (único por cuenta), el **`InfraDeployRole`** que asume el CI de infra y el **`DeployRole`** que asume el CI del backend. |
| `templates/bootstrap/ecr.yml` | `dev-assistant-ecr` | **Manual (consola/CLI)** | Repositorio **ECR** de la imagen del backend, con la imagen **placeholder** subida a mano (`scripts/push-placeholder.sh`) antes del primer deploy de `backend-service`. |
| `templates/infra/network.yaml` | `dev-assistant-network` | CI | VPC `10.20.0.0/16`, 2 subredes públicas (ALB/Fargate, 2 AZ) + 2 subredes privadas (RDS, sin ruta a Internet), Internet Gateway y rutas. Exporta `VpcId`, `PublicSubnet1/2`, `PrivateSubnet1/2`. |
| `templates/infra/security.yml` | `dev-assistant-security` | CI | Security Groups `alb-sg`, `app-sg` y `rds-sg`. Importa `VpcId`. Exporta `AlbSecurityGroupId`, `AppSecurityGroupId`, `RdsSecurityGroupId`. |
| `templates/infra/rds.yml` | `dev-assistant-rds` | CI | **RDS PostgreSQL 16**, Single-AZ, en las subredes privadas (importa `PrivateSubnet1/2` y `RdsSecurityGroupId`). Password maestra self-managed inyectada por `RDS_MASTER_PASSWORD` (secret de GitHub). La instancia tiene `DeletionPolicy`/`UpdateReplacePolicy: Snapshot`. Exporta `RdsEndpointAddress`, `RdsEndpointPort`. |
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
- **ecr** (manual): repositorio ECR de la imagen del backend, tags mutables (reusa
  `:latest` a propósito). Se despliega **a mano** igual que `bootstrap`, antes de que corra
  cualquier CI, para poder subirle la imagen **placeholder** con `scripts/push-placeholder.sh`
  (ver [Puesta en marcha](#puesta-en-marcha-una-sola-vez)) — así `backend-service` arranca
  con una tarea corriendo desde su primer deploy, sin depender de que el CI del backend
  haya corrido antes. `InfraDeployRole` (stack `bootstrap`) no tiene permisos `ecr:Create*`
  ni `ecr:Delete*`: no gestiona este stack.
- **network**: la decisión de costo está aquí — Fargate vive en subredes **públicas**
  (`MapPublicIpOnLaunch`) y sale a Internet por el IGW, evitando el NAT Gateway. Las 2
  subredes **privadas** (sin ruta al Internet Gateway) son solo para RDS: no necesitan
  NAT porque RDS no requiere salida a Internet.
- **security**: `app-sg` solo deja entrar al ALB (puerto 3000); `rds-sg` solo deja entrar
  a `app-sg` (puerto 5432). Ambos dependen del `VpcId` que exporta `network`.
- **rds**: Single-AZ, `db.t4g.micro`, 20 GB gp3, backups de 7 días, sin Performance
  Insights ni Enhanced Monitoring (costo/complejidad de MVP, ver `.checkov.yaml`). La
  password maestra es **self-managed** (no Secrets Manager, igual que el diseño previo):
  la inyecta el secret de GitHub `RDS_MASTER_PASSWORD` (ver
  [Puesta en marcha](#puesta-en-marcha-una-sola-vez) y `scripts/cfn.sh`), nunca vive en
  `params/*.json`. `DeletionPolicy`/`UpdateReplacePolicy: Snapshot` en el `DBInstance`
  garantiza que un borrado o reemplazo (p.ej. cambiar `DBInstanceIdentifier` o el motor)
  siempre deje un **snapshot final** — hay que borrarlo a mano si no se quiere seguir
  pagando su almacenamiento (ver [Notas](#notas)). Inmediatamente después de desplegar
  este stack, el workflow corre `scripts/cfn.sh set-database-url`: arma `DATABASE_URL`
  con el output `RdsEndpointAddress` + `RDS_MASTER_PASSWORD` y lo publica (SecureString)
  en `/dev-assistant/DATABASE_URL` — es idempotente y también mantiene el parámetro al
  día si el endpoint cambia (p.ej. tras un reemplazo).
- **ecs-cluster** / **alb** / **backend-service**: la tarea corre con
  `assignPublicIp: ENABLED`, `enableExecuteCommand: true` (depuración con ECS Exec) y
  _circuit breaker_ con rollback. Lee los 4 secretos desde SSM `/dev-assistant/*`.
  **`DesiredCount` arranca en 1** desde el primer deploy, gracias a la imagen placeholder
  subida a mano al stack `ecr`. No sube de 1: el contenedor corre `migrationsRun: true`
  (TypeORM) al boot, y tareas concurrentes se pisarían al aplicar las mismas migraciones
  (ver `dev-assistant-backend/docs/deployment.md`).
- **observability**: cubre ECS + ALB + logs; **RDS queda fuera** de las alarmas/dashboard
  en esta fase (no tiene métricas propias configuradas todavía, aunque ya es un stack de
  CloudFormation). El parámetro
  `AlarmEmail` (en `params/observability.json`) está vacío por defecto — sin él no se crea
  la suscripción SNS y las alarmas no notifican a nadie. Al completarlo y desplegar, AWS
  manda un mail de confirmación al endpoint que **hay que confirmar a mano** (si no, SNS
  descarta las notificaciones).

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
   sube `templates/bootstrap/github-oidc.yml`. Nombre de stack `dev-assistant-github-oidc`,
   reconoce la capacidad **IAM con nombres personalizados** (NAMED_IAM) y crea el stack.
   En la pestaña **Outputs** copia `InfraDeployRoleArn` y `DeployRoleArn`.
   > Si este stack **ya existía** de antes (sin el stack `rds`), hay que **actualizarlo**
   > a mano con la versión actual de `github-oidc.yml` (Update stack → Replace current
   > template) antes del paso 3: `InfraDeployRole` ahora también necesita los permisos
   > `rds:*` y `ssm:PutParameter` que usan el stack `rds` y `set-database-url`.

2. **Bootstrap del repositorio ECR y su placeholder (consola/CLI).** Con las mismas
   credenciales admin: despliega `templates/bootstrap/ecr.yml` (stack
   `dev-assistant-ecr`, sin capacidades especiales) — por consola igual que el paso 1, o
   con `bash scripts/cfn.sh deploy ecr` si ya tenés AWS CLI configurado. Después corré
   `bash scripts/push-placeholder.sh`: construye y sube a ese repo, como tag `:latest`,
   una imagen mínima (`placeholder/`) que responde `200 {"status":"ok"}` en `GET /health`.
   Esto deja `backend-service` listo para arrancar con `DesiredCount: 1` desde su primer
   deploy (paso 4), sin depender de que el CI del backend haya corrido antes. El primer
   push real de ese CI sobreescribe el mismo tag `:latest`.

3. **Configura este repositorio en GitHub** (Settings → Secrets and variables → Actions):
   - **Secret** `AWS_DEPLOY_ROLE_ARN` = `InfraDeployRoleArn` del paso 1.
   - **Secret** `RDS_MASTER_PASSWORD` = una contraseña fuerte que elijas vos (nunca va en
     `params/*.json` ni en git). El stack `rds` la usa como password maestra self-managed
     de la instancia, y el CI la reusa para componer `DATABASE_URL` automáticamente
     (ver paso 4).
   - **Variables**: `AWS_REGION` = `us-east-1`, `PROJECT_NAME` = `dev-assistant`.
   - En **Settings → Environments** crea `production` y añade _Required reviewers_ (gate de
     aprobación antes de cada deploy).

4. **Sube el repo y deja que el CI despliegue.** Con la rama `main` en GitHub, el push
   dispara el workflow: tras la aprobación del Environment `production`, despliega
   `network → security → rds → ecs-cluster → alb → observability → backend-service`.
   Justo después de `rds`, el paso **"Set DATABASE_URL in SSM"** arma la connection string
   con el output `RdsEndpointAddress` + `RDS_MASTER_PASSWORD` y la publica en
   `/dev-assistant/DATABASE_URL` — sin pasos manuales. El servicio ECS queda con **1 tarea
   corriendo la imagen placeholder** del paso 2 (`DesiredCount: 1`), sana detrás del ALB. Si
   querés recibir alarmas por email, completá `AlarmEmail` en `params/observability.json`
   antes de este paso (o después, con un redeploy del stack `observability`) y confirmá el
   mail que manda SNS.

5. **Crea los 3 secretos restantes en SSM por consola** (ver
   [Secretos en SSM](#paso-por-consola--secretos-en-ssm-parameter-store)): `DATABASE_URL`
   ya lo dejó el CI en el paso 4.

6. **Configura el repositorio del backend en GitHub** (ver
   [Variables y secretos del backend](#variables-y-secretos-de-github-backend)) con el
   output `DeployRoleArn` del paso 1 y los outputs de los stacks `ecs-cluster` y
   `backend-service`.

7. **Primer despliegue del backend.** El CI/CD del backend construye la imagen real, la
   publica en ECR (reemplazando el placeholder en el mismo tag `:latest`) y actualiza la
   tarea del servicio. A partir de aquí la API responde por `http://<AlbDnsName>` (output
   del stack `service`).

## Paso por consola — Secretos en SSM Parameter Store

La app necesita 3 secretos más que **no** van en CloudFormation (`DATABASE_URL` ya lo
escribe el CI automáticamente tras desplegar `rds`, ver [Puesta en marcha](#puesta-en-marcha-una-sola-vez)).
Créalos en la consola web, una sola vez:

1. Consola AWS → **Systems Manager → Parameter Store → Create parameter**.
2. Crea uno por cada **Name**:
   - `/dev-assistant/ANTHROPIC_API_KEY`
   - `/dev-assistant/OPENAI_API_KEY`
   - `/dev-assistant/JWT_SECRET` (valor largo y aleatorio)
3. En cada uno: **Tier** = Standard · **Type** = **SecureString** · **KMS key source** =
   _My current account_ con `alias/aws/ssm` (default) · pega el valor en **Value** →
   **Create parameter**.

> El rol de ejecución de ECS ya tiene permiso de lectura sobre `/dev-assistant/*`, que
> cubre los 4 secretos (los 3 de acá más `DATABASE_URL`).

> La app conecta con el **usuario master** a propósito: LangChain necesita ese privilegio
> para crear la extensión `vector` (pgvector) en el primer uso del RAG.

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
  `network → security → rds → ecs-cluster → alb → observability → backend-service`
  tras la **aprobación manual** del Environment `production`. Idempotente
  (`--no-fail-on-empty-changeset`).

> Los stacks `bootstrap` (`dev-assistant-github-oidc`) y `ecr` (`dev-assistant-ecr`) **no
> los gestiona el CI**: `bootstrap` define los propios roles `InfraDeployRole`/`DeployRole`
> que el CI asume, y `ecr` necesita existir con la imagen placeholder antes de que corra
> cualquier CI (ver [Puesta en marcha](#puesta-en-marcha-una-sola-vez)). Ambos se validan
> en cada PR pero solo se despliegan **a mano**.

> La imagen se mantiene en `:latest` (constante), así que redeployar la infra **no
> revierte** la imagen: el rollout real por SHA lo maneja el workflow del backend. El CI
> de infra crea el RDS (stack `rds`) y también escribe `DATABASE_URL` en SSM
> automáticamente; los otros 3 secretos (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
> `JWT_SECRET`) siguen siendo manuales por diseño (ver
> [Secretos en SSM](#paso-por-consola--secretos-en-ssm-parameter-store)).

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

> Con `DesiredCount: 1` la tarea de Fargate corre desde el primer deploy (imagen
> placeholder o real), así que ese costo aplica desde el paso 4 de
> [Puesta en marcha](#puesta-en-marcha-una-sola-vez), no desde el primer push del backend.

> Al borrar o reemplazar el `DBInstance` (stack `rds`), `DeletionPolicy`/
> `UpdateReplacePolicy: Snapshot` deja un **snapshot final** en AWS (~US$0.095/GB-mes, unos
> US$1.90/mes para 20 GB) que sigue facturando hasta que lo borres a mano — ver
> [Notas](#notas).

**Palancas de ahorro** (no activadas): `FARGATE_SPOT` (~70% menos cómputo, con riesgo de
interrupción), apagar la tarea de noche con scheduled scaling, o reemplazar el ALB por una
tarea pública directa (se pierde el WS gestionado).

## Verificación end-to-end

1. **Stacks OK**: en la consola de **CloudFormation**, los stacks `bootstrap`, `ecr`,
   `network`, `security`, `rds`, `ecs-cluster`, `alb`, `observability` y `backend-service`
   en `CREATE_COMPLETE` / `UPDATE_COMPLETE`.
2. **Salud**: `curl http://<AlbDnsName>/health` → `{"status":"ok"}` (valida ALB + tarea
   sana). Usa el output `AlbDnsName` del stack `alb`.
3. **Logs**: CloudWatch → `/ecs/dev-assistant-backend`. Debe verse que las **migraciones
   se aplicaron** y luego `DevAssistant API escuchando...` sin errores de TypeORM.
4. **App**: probar registro/login (JWT) y el chat (incluida la conexión WebSocket).
5. **CI/CD**: un push a `main` del repo backend debe construir, publicar en ECR y dejar el
   servicio `stable` con la nueva imagen.
6. **Observability**: abrí el output `DashboardUrl` del stack `observability` y confirmá
   que los widgets de ALB (requests, hosts saludables) muestran datos. Las alarmas deberían
   estar en `OK`, visibles en CloudWatch → Alarms con el prefijo `dev-assistant-`.

> La subida de documentos (S3), la ingesta asíncrona (SQS) y el PDF de stats (Lambda) están
> **fuera de esta fase**: el Task Role aún no tiene esos permisos.

## Notas

- **pgvector** no requiere pasos manuales: la extensión `vector` y la tabla `chunks` las
  crea LangChain (`PGVectorStore`) en el primer uso del RAG, con las credenciales master de
  RDS.
- **Para borrar todo**: corré `bash scripts/cfn.sh destroy-all` (`destroy` usa
  `delete-stack`, que no necesita parámetros, así que no hace falta `RDS_MASTER_PASSWORD`
  para borrar). Borra los 7 stacks CI-managed en orden inverso al de despliegue
  (`backend-service → observability → alb → ecs-cluster → rds → security → network`),
  esperando a que cada borrado termine antes de seguir con el siguiente. Al borrar el stack
  `rds`, `DeletionPolicy: Snapshot` deja un **snapshot final** de la instancia — si no
  querés seguir pagando su almacenamiento, borralo a mano después desde
  **RDS → Snapshots**. No toca `cicd-infra` (bootstrap) **ni** `ecr` a propósito: el
  primero para no invalidar el rol OIDC mientras el CI todavía lo necesita, y el segundo
  porque es manual (`bash scripts/cfn.sh destroy ecr` vacía el repo primero — si no,
  `delete-stack` falla con "repository not empty"). El stack `bootstrap` se borra aparte, a
  mano (`aws cloudformation delete-stack --stack-name dev-assistant-github-oidc`), y podés
  hacerlo en cualquier momento: al fusionar `InfraDeployRole` y `DeployRole` en el mismo
  template ya no queda ningún `Fn::ImportValue` de otro stack hacia su export
  `OidcProviderArn`.
