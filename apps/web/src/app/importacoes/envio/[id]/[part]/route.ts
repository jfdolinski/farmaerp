import { getError } from "@farmaerp/error-catalog";
import { apiUpload } from "@/lib/api";

/** Parte do .zip vinda do navegador, repassada à API com a sessão de quem enviou. */
export async function PUT(request: Request, { params }: { params: Promise<{ id: string; part: string }> }) {
  const { id, part } = await params;
  const body = await request.arrayBuffer();
  // O proxy do Next corta o corpo acima de 10 MB sem avisar: parte incompleta não segue.
  const declared = Number(request.headers.get("content-length"));
  if (!Number.isSafeInteger(declared) || declared !== body.byteLength) {
    const { code, message, action, retryable } = getError("FA741");
    return Response.json({ code, message, action, retryable, traceId: null }, { status: 422 });
  }
  const result = await apiUpload<{ received: number }>(
    `/admin/imports/${encodeURIComponent(id)}/parts/${encodeURIComponent(part)}`,
    body,
  );
  return Response.json(result.ok ? result.data : result.error, { status: result.ok ? 200 : 422 });
}
