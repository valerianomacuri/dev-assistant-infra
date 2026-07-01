# dev-assistant-infra

Infraestructura como código (CloudFormation) para **dev-assistant-backend**: una API
NestJS con PostgreSQL + pgvector y WebSockets. Optimizada como **MVP** y desplegada en
**us-east-1**.

> Este repositorio contiene **solo la infraestructura**, con su **propio CI/CD**. El
> código de la aplicación, su `Dockerfile` y el workflow que la construye y publica la
> imagen viven en el repositorio `dev-assistant-backend`.

> Para desplegar de cero, seguí la guía paso a paso: **[DEPLOY.md](DEPLOY.md)**. Este
> README se enfoca en la arquitectura y el porqué de cada decisión de diseño.

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

Cuenta de AWS con consola en **us-east-1** (perfil admin para el bootstrap manual, no
hace falta AWS CLI) y los repos de GitHub `dev-assistant-infra` (este) y
`dev-assistant-backend`. Detalle completo en [DEPLOY.md § 1](DEPLOY.md#1-antes-de-empezar).

## Puesta en marcha (una sola vez)

Tres fases: **bootstrap manual** (OIDC + roles, ECR + imagen placeholder) → **CI de
este repo** despliega `network → security → rds → ecs-cluster → alb → observability →
backend-service` tras push a `main` → **CI del backend** publica la imagen real y hace
el rollout. Pasos exactos, comandos y valores de cada secret/variable en
**[DEPLOY.md](DEPLOY.md)**.

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
> [DEPLOY.md, Paso 5](DEPLOY.md#paso-5--secretos-manuales-en-ssm-parameter-store)).

La lógica de despliegue vive en [`scripts/cfn.sh`](scripts/cfn.sh); el workflow la
ejecuta internamente y pasa los params de `params/*.json`. Referencia de comandos
(`validate`/`changeset`/`deploy`/`destroy`/`destroy-all`) en
[DEPLOY.md § 4](DEPLOY.md#4-referencia-rápida--scriptscfnsh).

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
> placeholder o real), así que ese costo aplica desde el deploy de `backend-service`
> (ver [Puesta en marcha](#puesta-en-marcha-una-sola-vez)), no desde el primer push del backend.

> Al borrar o reemplazar el `DBInstance` (stack `rds`), `DeletionPolicy`/
> `UpdateReplacePolicy: Snapshot` deja un **snapshot final** en AWS (~US$0.095/GB-mes, unos
> US$1.90/mes para 20 GB) que sigue facturando hasta que lo borres a mano — ver
> [Notas](#notas).

**Palancas de ahorro** (no activadas): `FARGATE_SPOT` (~70% menos cómputo, con riesgo de
interrupción), apagar la tarea de noche con scheduled scaling, o reemplazar el ALB por una
tarea pública directa (se pierde el WS gestionado).

## Verificación end-to-end

Checklist completo (stacks, `/health`, logs, app, CI/CD, dashboard) en
[DEPLOY.md § 5](DEPLOY.md#5-verificación-end-to-end).

> La subida de documentos (S3), la ingesta asíncrona (SQS) y el PDF de stats (Lambda) están
> **fuera de esta fase**: el Task Role aún no tiene esos permisos.

## Notas

- **pgvector** no requiere pasos manuales: la extensión `vector` y la tabla `chunks` las
  crea LangChain (`PGVectorStore`) en el primer uso del RAG, con las credenciales master de
  RDS. La app conecta con ese **usuario master** a propósito: LangChain necesita ese
  privilegio para crear la extensión.
- **Para borrar todo el entorno** (comandos y orden exacto): ver
  [DEPLOY.md § 6](DEPLOY.md#6-borrar-todo-teardown).
