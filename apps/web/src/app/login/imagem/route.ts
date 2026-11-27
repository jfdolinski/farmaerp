/**
 * Imagem da tela de entrada, repassada da API. Fica sob /login porque é vista antes de entrar.
 * O endereço leva o resumo da imagem (?v=), então o navegador guarda por bastante tempo.
 */
export async function GET(request: Request) {
  const apiUrl = process.env.API_URL ?? "http://127.0.0.1:3001";
  const ifNoneMatch = request.headers.get("if-none-match");
  let response: Response;
  try {
    response = await fetch(`${apiUrl}/public/login-image`, {
      cache: "no-store",
      signal: AbortSignal.timeout(15_000),
      headers: ifNoneMatch ? { "If-None-Match": ifNoneMatch } : {},
    });
  } catch {
    return new Response(null, { status: 503 });
  }
  const versioned = new URL(request.url).searchParams.has("v");
  const headers = new Headers({
    "Cache-Control": versioned ? "public, max-age=31536000, immutable" : "public, max-age=300",
  });
  const etag = response.headers.get("etag");
  if (etag) headers.set("ETag", etag);
  if (response.status === 304) return new Response(null, { status: 304, headers });
  if (!response.ok) return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
  headers.set("Content-Type", response.headers.get("content-type") ?? "application/octet-stream");
  return new Response(response.body, { status: 200, headers });
}
