import http from "k6/http";

// Fase A: CPU + latencia. Flood de POST /auth/login contra un email fijo
// inexistente. bcrypt (cost=12) sigue corriendo bcrypt.compare aunque el
// usuario no exista (comparación contra un hash dummy, por timing-safety),
// asi que esto genera carga real de CPU sin escribir nada en la DB.
//
// 250 VUs es el default recomendado: en la prueba real, 60 VUs apenas movió
// CPU/memoria (el cuello de botella real termina siendo el pool de
// conexiones a Postgres, no bcrypt en sí), pero ~260 VUs concurrentes llevó
// CPU de ~5% a ~94% y memoria de ~9% a ~57% (y subiendo) en unos 5 minutos.
//
// Override sin tocar el archivo:
//   k6 run --vus 300 --duration 20m loadtest-auth.js

const BASE_URL = __ENV.BASE_URL || "http://dev-assistant-alb-906745220.us-east-1.elb.amazonaws.com";

export const options = {
  vus: Number(__ENV.VUS || 250),
  duration: __ENV.DURATION || "18m",
};

const payload = JSON.stringify({
  email: "nobody@loadtest.local",
  password: "wrong-password-123",
});

const params = {
  headers: { "Content-Type": "application/json" },
};

export default function () {
  http.post(`${BASE_URL}/auth/login`, payload, params);
}
