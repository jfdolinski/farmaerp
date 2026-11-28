import { apiDownload } from "@/lib/api";

const FILES: Record<string, { type: string; fallback: string }> = {
  xml: { type: "application/xml; charset=utf-8", fallback: "CCe.xml" },
  pdf: { type: "application/pdf", fallback: "CCe.pdf" },
};

/** XML ou PDF de uma carta de correção, repassados da API com a sessão de quem pediu. */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string; file: string }> }) {
  const { id, file } = await params;
  const kind = FILES[file];
  if (!kind) return new Response(null, { status: 404 });
  const response = await apiDownload(`/admin/nfe-corrections/file/${encodeURIComponent(id)}/${file}`);
  if (!response.ok) {
    return new Response("Não foi possível baixar a carta de correção. Volte à nota e tente de novo.", {
      status: response.status,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return new Response(await response.arrayBuffer(), {
    headers: {
      "Content-Type": kind.type,
      "Content-Disposition": response.headers.get("content-disposition") ?? `attachment; filename="${kind.fallback}"`,
    },
  });
}
