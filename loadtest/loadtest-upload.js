import http from "k6/http";
import { check } from "k6";

// Fase B: memoria (complementaria a la Fase A, no aislada). Sube un archivo
// de ~20MB repetidamente a POST /documents (requiere JWT). El TaskRole del
// backend no tiene permisos de S3, así que la subida falla con AccessDenied
// del lado del servidor DESPUÉS de bufferear el archivo completo en memoria
// (Multer memoryStorage) - no genera costo real de S3/embeddings ni filas
// huérfanas en Document (el insert es posterior al upload a S3 en el código).
//
// Ojo: en la prueba real esta fase quedó limitada por el ancho de banda de
// SUBIDA de la máquina que la corre (~26GB enviados en 8 min ≈ 53MB/s
// sostenido acá; la mayoría de los requests tardaron 11-23s en fallar). Sola
// no alcanza para mover memoria mucho - córrela en paralelo con
// loadtest-auth.js, que es lo que realmente empuja memoria hacia 80%.
//
// Antes de correr, generar el payload en esta misma carpeta:
//   PowerShell:  fsutil file createnew payload.txt 20971520
//   Git Bash:    head -c 20971520 /dev/urandom > payload.txt

const BASE_URL = __ENV.BASE_URL || "http://dev-assistant-alb-906745220.us-east-1.elb.amazonaws.com";

export const options = {
  vus: Number(__ENV.VUS || 48),
  duration: __ENV.DURATION || "8m",
};

// Se lee una sola vez en el init context, compartido (copy-on-write) entre
// todas las VUs - no se regenera en cada iteración.
const payloadBin = open("./payload.txt", "b");

export function setup() {
  const email = `loadtest+${Date.now()}@example.com`;
  const res = http.post(
    `${BASE_URL}/auth/register`,
    JSON.stringify({ email, password: "LoadTest123!" }),
    { headers: { "Content-Type": "application/json" } },
  );
  check(res, { "register ok": (r) => r.status === 200 || r.status === 201 });
  const token = res.json("accessToken");
  return { token };
}

export default function (data) {
  const body = {
    file: http.file(payloadBin, "payload.txt", "text/plain"),
  };
  const params = {
    headers: { Authorization: `Bearer ${data.token}` },
  };
  http.post(`${BASE_URL}/documents`, body, params);
}
