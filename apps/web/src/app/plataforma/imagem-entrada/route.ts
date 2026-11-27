import { getError } from "@farmaerp/error-catalog";
import { apiUpload } from "@/lib/api";

const TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const MAX_BYTES = 3 * 1024 * 1024;

function refused(code: string, status: number) {
  const { message, action, retryable } = getError(code);
  return Response.json({ code, message, action, retryable, traceId: null }, { status });
}

/** Imagem da tela de entrada vinda do navegador (já reduzida lá), repassada à API com a sessão. */
export async function PUT(request: Request) {
  const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  const declared = Number(request.headers.get("content-length"));
  if (!TYPES.has(type) || !Number.isSafeInteger(declared) || declared < 1 || declared > MAX_BYTES) {
    return refused("FA225", 422);
  }
  const body = await request.arrayBuffer();
  if (body.byteLength !== declared) return refused("FA225", 422);
  const result = await apiUpload<{ sha256: string }>("/platform/login-image", body, type);
  if (result.ok) return Response.json(result.data);
  const status = result.error.code === "FA402" ? 401 : result.error.code === "FA002" ? 403 : 422;
  return Response.json(result.error, { status });
}
