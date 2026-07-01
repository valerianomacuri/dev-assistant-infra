import http from "k6/http";

// Escalada opcional para dev-assistant-alb-unhealthy-hosts, solo si no se
// disparó sola mientras loadtest-auth.js / loadtest-upload.js estaban en su
// pico combinado. Flood directo a GET /health con concurrencia muy alta para
// saturar la capacidad de aceptar conexiones de ambas tasks a la vez.
//
// Es el paso más agresivo de los tres: puede tirar el servicio a 0 hosts
// saludables por un rato breve. Correrlo por poco tiempo (2-3 min alcanza,
// el unhealthy threshold del target group es 3 checks de 30s = 90s).

const BASE_URL = __ENV.BASE_URL || "http://dev-assistant-alb-906745220.us-east-1.elb.amazonaws.com";

export const options = {
  vus: Number(__ENV.VUS || 500),
  duration: __ENV.DURATION || "2m30s",
};

export default function () {
  http.get(`${BASE_URL}/health`);
}
