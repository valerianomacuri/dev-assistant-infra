# syntax=docker/dockerfile:1

# Imagen placeholder para el primer deploy de backend-service (DesiredCount: 1
# desde el arranque, sin depender de que el CI del backend haya corrido antes).
# nginx (no root, corre en el puerto 3000 sin privilegios) responde 200 en
# GET /health con el mismo shape que
# dev-assistant-backend/src/health/health.controller.ts, para que el Target
# Group del ALB (HealthCheckPath: /health) lo marque sano. Se sube a mano una
# sola vez con scripts/push-placeholder.sh; el primer push real del CI del
# backend lo reemplaza en el tag `:latest`.

FROM nginxinc/nginx-unprivileged:alpine-slim
COPY default.conf /etc/nginx/conf.d/default.conf
EXPOSE 3000
