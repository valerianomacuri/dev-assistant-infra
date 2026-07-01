# Prueba de carga para disparar las alarmas de CloudWatch

Scripts de [k6](https://k6.io/) para disparar deliberadamente las alarmas
definidas en `templates/infra/observability.yml` y confirmar que las métricas
y las notificaciones (SNS → email) funcionan de punta a punta:

- `dev-assistant-ecs-cpu-high`
- `dev-assistant-ecs-memory-high`
- `dev-assistant-alb-unhealthy-hosts`
- `dev-assistant-alb-response-time-high`

Como bonus, es esperable que también se dispare `dev-assistant-alb-5xx-high` y
`dev-assistant-backend-error-logs-high` (efecto secundario de los timeouts /
errores generados) — es una buena señal, no un problema.

## 1. Prerrequisitos

1. Instalar k6:
   ```powershell
   winget install --id GrafanaLabs.k6 -e --source winget
   ```
   (el id `k6.k6` no existe en winget, tiene que ser `GrafanaLabs.k6`).
   Confirmar con `k6 version`.

2. Confirmar que el servicio ECS tiene 2 tasks `RUNNING`:
   ```bash
   aws ecs describe-services --cluster dev-assistant --services dev-assistant-backend \
     --query 'services[0].{Desired:desiredCount,Running:runningCount}'
   ```

3. Generar el archivo de payload de ~20MB para `loadtest-upload.js`, **dentro
   de esta misma carpeta**:
   ```powershell
   fsutil file createnew payload.txt 20971520
   ```
   o en Git Bash:
   ```bash
   head -c 20971520 /dev/urandom > payload.txt
   ```

## 2. Riesgos / blast radius (leer antes de correr)

- **Disrupción real de servicio durante la prueba** (~20-25 min en total): con
  las 2 tasks saturadas a propósito, cualquier uso real de la app en ese
  momento va a sentir latencia alta o errores. Correrlo en un momento de bajo
  uso.
- `loadtest-health-flood.js` es el paso más agresivo: puede tirar el servicio
  a **0 hosts saludables** brevemente.
- No se espera costo adicional real: los uploads en `loadtest-upload.js`
  fallan con AccessDenied de S3 antes de completar el flujo (el `TaskRole` no
  tiene permisos de S3/SQS), así que no hay costo de storage ni de embeddings,
  ni filas huérfanas en `Document`.
- Sí va a quedar **una fila descartable en la tabla `User`** (email
  `loadtest+<timestamp>@example.com`) por el `POST /auth/register` que hace
  `loadtest-upload.js` en su `setup()`. Limpiar a mano con un DELETE si se
  quiere.
- Vas a recibir varios emails de SNS — cada alarma notifica al entrar en
  `ALARM` y al volver a `OK`. Es justamente lo que se quiere validar.

## 3. Cómo correr

1. En una terminal, arrancar la Fase A (CPU + latencia):
   ```bash
   k6 run loadtest-auth.js
   ```
   Por defecto usa **250 VUs durante 18 minutos**. Esto no es arbitrario: en
   una prueba real, 60 VUs apenas movió CPU/memoria (el cuello de botella
   termina siendo el pool de conexiones a Postgres, no bcrypt en sí mismo),
   pero ~260 VUs concurrentes llevó CPU de ~5% a ~94% y memoria de ~9% a ~57%
   (y subiendo) en unos 5 minutos. Si a los ~5 min `CPUUtilization` sigue sin
   subir, subir la concurrencia sin tocar el archivo:
   ```bash
   k6 run --vus 350 --duration 20m loadtest-auth.js
   ```

2. ~2 minutos después, en **otra terminal**, arrancar la Fase B (memoria,
   complementaria — no reemplaza a la Fase A, la refuerza):
   ```bash
   k6 run loadtest-upload.js
   ```
   Va a mostrar muchos requests fallidos (esperado, ver sección de riesgos).
   Si `MemoryUtilization` no se acerca a 80% (819MB de 1024MB), subir VUs de a
   incrementos (`k6 run --vus 64 ...`, luego 80). Ir con cautela: si se ve que
   se acerca al límite duro de 1024MB, cortar (Ctrl+C) para evitar un
   OOM-kill de la task (no es grave, ECS la reinicia sola en 1-2 min, pero
   puede interferir con la Fase A en curso).

3. Ir monitoreando el estado de las alarmas cada 1-2 minutos:
   ```bash
   aws cloudwatch describe-alarms --alarm-name-prefix dev-assistant- \
     --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' --output table
   ```
   Y si hace falta ver las métricas crudas (por ejemplo para decidir si subir
   VUs):
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/ECS --metric-name CPUUtilization \
     --dimensions Name=ClusterName,Value=dev-assistant Name=ServiceName,Value=dev-assistant-backend \
     --start-time "$(date -u -d '-15 minutes' +%Y-%m-%dT%H:%M:%S)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
     --period 60 --statistics Average --query 'sort_by(Datapoints,&Timestamp)[].{T:Timestamp,CPU:Average}'
   ```

4. Si a los ~5 minutos de la Fase A + B corriendo juntas no hay señal de
   `dev-assistant-alb-unhealthy-hosts`, escalar con el tercer script en una
   tercera terminal:
   ```bash
   k6 run loadtest-health-flood.js
   ```

## 4. Cómo cortar y verificar

1. Cortar todos los `k6 run` en curso (Ctrl+C en cada terminal).
2. Esperar a que el sistema se estabilice y confirmar que las 4 alarmas
   volvieron a `OK`:
   ```bash
   aws cloudwatch describe-alarms --alarm-name-prefix dev-assistant- \
     --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' --output table
   ```
3. Revisar el historial de cada alarma como evidencia del ciclo completo
   (OK → ALARM → OK):
   ```bash
   aws cloudwatch describe-alarm-history --alarm-name dev-assistant-ecs-cpu-high
   aws cloudwatch describe-alarm-history --alarm-name dev-assistant-ecs-memory-high
   aws cloudwatch describe-alarm-history --alarm-name dev-assistant-alb-unhealthy-hosts
   aws cloudwatch describe-alarm-history --alarm-name dev-assistant-alb-response-time-high
   ```
4. Confirmar que llegaron los emails de SNS para cada transición.

## 5. Limpieza opcional

Borrar la fila de `User` de prueba creada por `loadtest-upload.js`
(`loadtest+...@example.com`), conectándose a la base con tu cliente de
Postgres habitual.
