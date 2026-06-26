# dev-assistant-infra

Infraestructura como código (CloudFormation) para **dev-assistant-backend**, una
API NestJS con Postgres + pgvector y WebSockets. Optimizada para un **MVP en
Perú**, desplegada en **us-east-1**.

> Este repo contiene **solo la infraestructura**, con su **propio CI/CD** (ver
> _CI/CD de la infraestructura_). El código de la app, su `Dockerfile` y el
> workflow que la construye y despliega viven en el repo `dev-assistant-backend`.

## Arquitectura

```
Internet ──HTTPS:443──> ALB (público) ──HTTP:3000──> ECS Fargate (1 tarea, subred pública, IP pública)
                                                              │ (egress directo por IGW, sin NAT)
                                                              └──5432──> RDS PostgreSQL 16 (red propia, no en el stack)
```

- **Fargate en subredes públicas con IP pública** → evita el costo de un NAT
  Gateway. El Security Group de la app solo acepta tráfico del ALB en el 3000.
- **RDS** no público, accesible solo desde el SG de la app. **Se crea a mano por
  consola con su propia red** (DB subnet group + security group manuales) — **no
  forma parte del stack de red** ni de ningún otro stack.
- **HTTPS** terminado en el ALB (certificado ACM). WebSockets de socket.io
  funcionan de forma nativa sobre el ALB, con stickiness para el long-polling.
- **Secretos**: las 4 variables sensibles (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `JWT_SECRET`, `DATABASE_URL`) van en **SSM Parameter Store** (SecureString,
  gratis). No se usa Secrets Manager.

## Stacks (4 capas)

Se enlazan con `Export`/`ImportValue`. **RDS no es un stack** — se crea por consola
(ver más abajo). El CI/CD del **infra** y el del **backend** están **separados** en
dos stacks distintos: `00-cicd-infra` (bootstrap **manual**) y `02-cicd-backend`
(lo gestiona el CI).

| Plantilla | Stack | Despliega | Qué crea |
|-----------|-------|-----------|----------|
| `templates/00-cicd-infra.yaml` | `dev-assistant-cicd-infra` | **Manual** (bootstrap) | Proveedor **OIDC** de GitHub (único por cuenta) y el **`InfraDeployRole`** que asume el CI de infra. Exporta `OidcProviderArn`. |
| `templates/01-network.yaml` | `dev-assistant-network` | CI | VPC `10.20.0.0/16`, 2 subredes públicas (2 AZ), Internet Gateway y rutas, y 2 Security Groups (`alb-sg`, `app-sg`) encadenados. |
| `templates/02-cicd-backend.yaml` | `dev-assistant-cicd-backend` | CI | Repositorio **ECR** y el **`DeployRole`** que asume el CI del backend para publicar imágenes y desplegar en ECS. Importa `OidcProviderArn`. |
| `templates/03-service.yaml` | `dev-assistant-service` | CI | Certificado **ACM**, **ALB** (HTTP→HTTPS + WS), **cluster ECS**, **task definition**, **servicio Fargate**, roles de ejecución/tarea y log group. |

### Recursos clave por stack

- **00-cicd-infra** (bootstrap manual): crea el **proveedor OIDC** de GitHub y el
  `InfraDeployRole`, que confía en `repo:<org>/dev-assistant-infra:*`. Exporta
  `OidcProviderArn` para que el stack `cicd-backend` lo reutilice. Se despliega a
  mano una sola vez porque define el propio rol que usa el CI (ver _Puesta en
  marcha_). El proveedor OIDC es **único por cuenta**: este stack asume que la
  cuenta aún no tiene uno de GitHub.
- **01-network**: la decisión de costo está aquí — Fargate vive en las subredes
  **públicas** (`MapPublicIpOnLaunch`) y sale a Internet por el IGW, así no hace
  falta NAT Gateway (~US$32/mes). `app-sg` solo deja entrar al ALB. El **RDS no
  está aquí**: trae su propio subnet group y security group creados a mano (ver
  _Crear RDS_).
- **02-cicd-backend**: el `DeployRole` confía en `repo:<org>/dev-assistant-backend:*`
  vía OIDC y solo puede empujar a su ECR y actualizar el servicio ECS. **Importa**
  el proveedor OIDC del stack `cicd-infra` (no lo recrea).
- **03-service**: la tarea corre con `assignPublicIp: ENABLED`,
  `enableExecuteCommand: true` (para depurar con ECS Exec) y circuit breaker con
  rollback. Lee las 4 variables sensibles desde SSM `/dev-assistant/*`. Las
  migraciones de TypeORM se aplican solas al arrancar la tarea.

## Requisitos previos

- AWS CLI v2 configurado (`aws configure`) con un perfil admin en **us-east-1**.
- `jq` instalado (lo usa `scripts/cfn.sh` para componer los parámetros).
- Un dominio para la API (p.ej. `api.tudominio.com`). Para un **dominio
  personalizado** crea una **zona alojada (hosted zone) en Route53** para ese
  dominio y delega los nameservers de tu registrador a Route53; luego apunta su
  `HostedZoneId` para validar el certificado automáticamente. Si prefieres no usar
  Route53, la validación DNS del certificado ACM es **manual** (añadir el registro
  CNAME de validación en tu DNS a mano).
- El repo `dev-assistant-backend` en GitHub (para el OIDC y el CI/CD del backend).
- **Este repo (`dev-assistant-infra`) también en GitHub**: su CI/CD asume el
  `InfraDeployRole`, cuya confianza OIDC está ligada a
  `repo:<org>/dev-assistant-infra:*`.

## Orden de despliegue

Los parámetros **estáticos** están en `params/*.json`. Los **específicos de
cuenta/entorno** (`GitHubOrg`, `DomainName`, `ImageUri`) los resuelve
CloudFormation directamente desde **SSM Parameter Store** (parámetros de tipo
`AWS::SSM::Parameter::Value`); **deben existir en SSM antes de desplegar** o el
stack falla con un error de validación (ver _Parámetros de CloudFormation en SSM_).
Región **us-east-1** en todos los comandos.

```bash
# 0) Crea /dev-assistant/cfn/GitHubOrg en SSM antes de nada (lo necesitan los dos
#    stacks de CI/CD). Ver "Parámetros de CloudFormation en SSM".

# 1) Bootstrap del CI de infra (MANUAL): OIDC + InfraDeployRole. Exporta el OIDC.
bash scripts/cfn.sh deploy 00-cicd-infra

# 2) Red
bash scripts/cfn.sh deploy 01-network

# 3) CI/CD del backend: ECR + DeployRole (importa el OIDC del paso 1)
bash scripts/cfn.sh deploy 02-cicd-backend
```

> A partir del paso 2 el CI de infra ya puede gestionar `network`, `cicd-backend`
> y `service`. El stack `00-cicd-infra` queda fuera del CI (es bootstrap manual).

Luego:

3. **Crea el RDS por consola** (ver _Crear RDS_ más abajo) con su **propia red**
   (subnet group + security group manuales). Copia su **Endpoint**.
4. **Crea los 4 secretos en SSM** (ver _Secretos en SSM_), incluido
   `/dev-assistant/DATABASE_URL` con el endpoint del RDS.
5. **Crea los parámetros `/dev-assistant/cfn/DomainName` e
   `/dev-assistant/cfn/ImageUri` en SSM** (`GitHubOrg` ya en el paso 0). Ver
   _Parámetros de CloudFormation en SSM_. `CertificateArn`/`HostedZoneId` son
   opcionales y van en `params/03-service.json` solo si los necesitas.
   - **Para un dominio personalizado**: crea la **zona alojada de Route53** del
     dominio **antes** de desplegar el `service` y pon su `HostedZoneId` en
     `params/03-service.json`. Así el stack crea el certificado ACM y lo valida
     por DNS automáticamente. Sin Route53, deja `HostedZoneId` vacío y valida el
     certificado a mano en tu DNS.
6. **Configura los secrets/variables de GitHub** en el repo del backend
   (output `DeployRoleArn` del stack `cicd-backend` + valores del `service`).
7. **Primer build de la imagen** (dispara el workflow o build manual) para que
   ECR tenga una imagen que la tarea pueda arrancar; deja `/dev-assistant/cfn/ImageUri`
   apuntando a ella.
8. **Servicio** (necesita `/dev-assistant/cfn/ImageUri` apuntando a una imagen real
   ya en ECR):

```bash
bash scripts/cfn.sh deploy 03-service
```

9. **Apunta el dominio al ALB**: dentro de la **zona alojada de Route53** del
   dominio (paso 5), crea un registro **alias A** de `api.tudominio.com` → el
   `AlbDnsName` del output del stack `service`. Si tu DNS no está en Route53, usa
   un **CNAME** equivalente en tu proveedor.

> Outputs útiles: `aws cloudformation describe-stacks --stack-name dev-assistant-cicd-infra --query "Stacks[0].Outputs"` (igual para `dev-assistant-cicd-backend` y `dev-assistant-service`).

## Paso por consola — Crear RDS PostgreSQL

RDS **no** está en CloudFormation; se crea a mano con su **propia red**. Reutiliza
la VPC del stack `01` (`dev-assistant-vpc`), pero el subnet group y el security
group del RDS se crean **manualmente** (no salen de ningún stack).

1. **EC2 → Security Groups → Create security group**: name
   `dev-assistant-rds-sg`, VPC `dev-assistant-vpc`. Una regla **inbound**: tipo
   **PostgreSQL** (TCP 5432) con **Source = el SG de la app** (`dev-assistant-app-sg`,
   el del output `AppSecurityGroupId` del stack `01`). Sin otras reglas.
2. **RDS → Subnet groups → Create DB subnet group**: name
   `dev-assistant-db-subnets`, VPC `dev-assistant-vpc`, con subredes en **2 AZ**.
   Recomendado para el MVP: usa las **2 subredes públicas** del stack
   (`dev-assistant-public-1`, `dev-assistant-public-2`) y deja **Public access = No**
   (el acceso queda restringido por el SG, no por la subred). Si prefieres
   aislamiento de red, crea a mano 2 subredes privadas propias y úsalas aquí.
3. **RDS → Databases → Create database** → **Standard create**:
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
4. **Create database** → espera a **Available** → copia el **Endpoint**.

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

## Parámetros de CloudFormation en SSM

Los parámetros **específicos de cuenta/entorno** **no** viven en git: se declaran
en los templates como tipo `AWS::SSM::Parameter::Value<String>` con
`Default: /dev-assistant/cfn/<clave>`, así que **CloudFormation resuelve el valor
directamente desde SSM Parameter Store** en cada deploy (no hay paso intermedio ni
override). Los **estáticos** (ProjectName, CPU, memoria, modelos, etc.) siguen en
`params/*.json`.

| Parámetro SSM (`Name`) | Stack | Valor |
|---|---|---|
| `/dev-assistant/cfn/GitHubOrg` | `cicd-infra`, `cicd-backend` | Org/usuario de GitHub dueño de los repos. |
| `/dev-assistant/cfn/DomainName` | `service` | Dominio de la API (p.ej. `api.tudominio.com`). |
| `/dev-assistant/cfn/ImageUri` | `service` | URI completa en ECR, p.ej. `<account>.dkr.ecr.us-east-1.amazonaws.com/dev-assistant-backend:latest`. |

> **Los tres deben existir en SSM antes del deploy del stack que los usa**
> (`GitHubOrg` antes de `cicd-infra`/`cicd-backend`; `DomainName` e `ImageUri`
> antes de `service`). Si falta el parámetro, CloudFormation devuelve un error de
> validación.

Créalos en **Systems Manager → Parameter Store → Create parameter** con **Tier**
Standard y **Type = String** (no son secretos, no uses SecureString). Por CLI:

```bash
aws ssm put-parameter --region us-east-1 --type String \
  --name /dev-assistant/cfn/GitHubOrg --value valerianomacuri
aws ssm put-parameter --region us-east-1 --type String \
  --name /dev-assistant/cfn/DomainName --value api.tudominio.com
aws ssm put-parameter --region us-east-1 --type String \
  --name /dev-assistant/cfn/ImageUri \
  --value "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com/dev-assistant-backend:latest"
```

> `CertificateArn` y `HostedZoneId` **no** van en SSM: son parámetros opcionales
> normales (default `""`) en `params/03-service.json`. Déjalos vacíos para que el
> stack cree el certificado; rellénalos solo si reutilizas un certificado ACM o
> quieres validación DNS automática por Route53. (Se quedan como `String` porque un
> tipo `AWS::SSM::Parameter::Value` exigiría que el parámetro existiera siempre, y
> SSM no admite valores vacíos.)
>
> **Dominio personalizado (camino recomendado)**: crea una **zona alojada en
> Route53** para tu dominio → pon su `HostedZoneId` en `params/03-service.json` →
> el stack crea el certificado ACM y lo **valida por DNS automáticamente**, sin
> pasos manuales.

## Variables y secretos de GitHub (repo del backend)

En **Settings → Secrets and variables → Actions** del repo `dev-assistant-backend`:

- **Secret** `AWS_ROLE_ARN` = output `DeployRoleArn` del stack `cicd-backend`.
- **Variables** (Repository variables):
  - `AWS_REGION` = `us-east-1`
  - `ECR_REPOSITORY` = `dev-assistant-backend`
  - `ECS_CLUSTER` = `dev-assistant`
  - `ECS_SERVICE` = `dev-assistant-backend`
  - `ECS_TASK_FAMILY` = `dev-assistant-backend`
  - `CONTAINER_NAME` = `app`

## CI/CD de la infraestructura

Este repo tiene un workflow ([`.github/workflows/deploy-infra.yml`](.github/workflows/deploy-infra.yml))
que valida y despliega los stacks de CloudFormation con GitHub Actions + OIDC
(sin llaves estáticas). El despliegue a mano de _Orden de despliegue_ pasa a ser
el **bootstrap/fallback**; el camino normal es por **Pull Request**.

**Flujo:**

- **En cada PR**: `cfn-lint` (sintaxis), `checkov` (seguridad, en _soft-fail_),
  `validate-template`, y un **plan** que crea _change sets_ para previsualizar el
  diff de cada stack y lo publica como comentario del PR. **No cambia nada.**
- **En push a `main`** (o `workflow_dispatch`): despliega en orden
  `network` → `cicd-backend` → `service` tras la **aprobación manual** del
  Environment `production`. Idempotente (`--no-fail-on-empty-changeset`).

> El stack de bootstrap **`00-cicd-infra` no lo gestiona el CI** (define el propio
> `InfraDeployRole` que el CI asume): se valida en cada PR pero solo se despliega a
> mano (ver _Puesta en marcha_).

> El `ImageUri` se lee de `/dev-assistant/cfn/ImageUri` (SSM) y se mantiene en
> `:latest` (constante), así que redeployar la infra **no revierte** la imagen: el
> rollout real por SHA lo sigue manejando el workflow del backend. El CI de infra
> **no** crea RDS ni los parámetros/secretos de SSM (siguen siendo manuales por
> diseño).

La lógica de AWS CLI vive en [`scripts/cfn.sh`](scripts/cfn.sh)
(`validate` | `changeset <slug>` | `deploy <slug>`), reutilizable en local:
`bash scripts/cfn.sh changeset 03-service`. Pasa los params estáticos de
`params/*.json`; los de `/dev-assistant/cfn/*` los resuelve CloudFormation solo.

### Puesta en marcha (una sola vez)

Paso a paso para dejar el CI/CD operativo partiendo de un repo local recién
inicializado (rama `master`, sin remoto, con `.github/` y `scripts/` aún sin
commitear):

1. **Crea `/dev-assistant/cfn/GitHubOrg` en SSM** (lo necesitan los stacks
   `cicd-infra` y `cicd-backend`). Ver _Parámetros de CloudFormation en SSM_.
2. **Bootstrap del CI de infra** — el stack `00-cicd-infra.yaml` define el
   proveedor OIDC y el `InfraDeployRole` (el rol que asume este CI). Despliégalo
   **a mano** una vez; a partir de ahí el CI ya puede gestionar `network`,
   `cicd-backend` y `service`. Copia el output `InfraDeployRoleArn`:

   ```bash
   bash scripts/cfn.sh deploy 00-cicd-infra
   aws cloudformation describe-stacks --region us-east-1 \
     --stack-name dev-assistant-cicd-infra \
     --query "Stacks[0].Outputs[?OutputKey=='InfraDeployRoleArn'].OutputValue" \
     --output text
   ```

   > **Migración desde un stack `dev-assistant-cicd` ya existente** (antes de la
   > separación): los roles (`dev-assistant-github-deploy`,
   > `dev-assistant-infra-deploy`) y el OIDC son de **nombre único**, así que los
   > dos stacks nuevos chocarían con el viejo. **Borra primero** el stack
   > `dev-assistant-cicd` (eso libera el OIDC y los roles) y luego despliega
   > `00-cicd-infra` + `02-cicd-backend`.

3. **Crea el repo `dev-assistant-infra` en GitHub** (vacío, sin README ni
   `.gitignore` para evitar conflictos al hacer push).
4. **Commitea los archivos nuevos** del repo (`.github/`, `scripts/`, `.cfnlintrc`,
   `.checkov.yaml` y los cambios de `templates/`, `params/`, `README.md`):

   ```bash
   git add -A
   git commit -m "infra: CI/CD con GitHub Actions + parámetros desde SSM"
   ```

5. **Renombra la rama a `main`** (el workflow solo dispara en `main`):

   ```bash
   git branch -m master main
   ```

6. **Añade el remoto y haz push**:

   ```bash
   git remote add origin git@github.com:<org>/dev-assistant-infra.git
   git push -u origin main
   ```

7. **Environment `production`** — en **Settings → Environments** del repo, crea
   `production` y añade _Required reviewers_ (eso materializa la aprobación manual
   antes de cada deploy).
8. **Secrets/Variables de GitHub** de **este repo** (no el del backend), en
   **Settings → Secrets and variables → Actions**:
   - **Secret** `AWS_DEPLOY_ROLE_ARN` = output `InfraDeployRoleArn` del stack
     `cicd-infra`.
   - **Variable** `AWS_REGION` = `us-east-1`.
9. **Prueba el flujo**: abre un PR → corren `validate` + `plan` (comenta el diff de
   los change sets, sin cambiar nada). Haz merge a `main` → corre `deploy` tras la
   aprobación del Environment `production`.

## Estimación de costos (us-east-1, ~mensual)

| Recurso | Aprox. |
|---|---|
| Fargate 0.5 vCPU / 1 GB 24/7 | ~US$18 |
| ALB | ~US$16 + LCU |
| RDS db.t4g.micro single-AZ + 20 GB gp3 | ~US$15 |
| SSM Parameter Store (Standard, String + SecureString) | gratis |
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
- Para borrar todo, elimina **primero a mano** el RDS y su red propia (la
  instancia `dev-assistant-postgres` —con snapshot final si quieres conservar los
  datos—, luego el DB subnet group `dev-assistant-db-subnets` y el security group
  `dev-assistant-rds-sg`) y después los stacks en orden inverso (`service` →
  `cicd-backend` → `network` → `cicd-infra`). Borra `cicd-infra` al final: el
  `cicd-backend` importa su export `OidcProviderArn` y CloudFormation no deja
  eliminar un stack mientras otro consume su export. Si el RDS sigue vivo y usara
  subredes del stack `network`, su borrado bloquearía la eliminación del stack.
