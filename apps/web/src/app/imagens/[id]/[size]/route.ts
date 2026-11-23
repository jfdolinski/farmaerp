import { apiDownload } from "@/lib/api";

/**
 * Repassa a imagem do Catálogo da API, com a sessão de quem pediu: o navegador não fala direto
 * com a API. O cache e o ETag seguem os da API, e o 304 volta sem baixar de novo.
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string; size: string }> }) {
  const { id, size } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id) || (size !== "full" && size !== "thumb")) {
    return new Response(null, { status: 404 });
  }
  const etag = request.headers.get("if-none-match");
  const response = await apiDownload(`/admin/catalog-images/${id}/${size}`, etag ? { "If-None-Match": etag } : {});
  const headers = new Headers();
  for (const name of ["etag", "cache-control"]) {
    const value = response.headers.get(name);
    if (value) headers.set(name, value);
  }
  if (response.status === 304) return new Response(null, { status: 304, headers });
  if (!response.ok) return new Response(null, { status: response.status });
  headers.set("Content-Type", "image/webp");
  return new Response(await response.arrayBuffer(), { headers });
}
