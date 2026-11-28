import { apiDownload } from "@/lib/api";

const FILES: Record<string, { path: string; type: string; fallback: string }> = {
  xml: { path: "xml", type: "application/xml; charset=utf-8", fallback: "NFe.xml" },
  danfe: { path: "danfe", type: "application/pdf", fallback: "DANFE.pdf" },
  cancelamento: { path: "xml?kind=cancel", type: "application/xml; charset=utf-8", fallback: "Cancelamento-NFe.xml" },
};

/** XML, DANFE ou XML do cancelamento da NF-e emitida pela central (devolução ou transferência), repassados da API com a sessão de quem pediu. */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string; file: string }> }) {
  const { id, file } = await params;
  const kind = FILES[file];
  if (!kind) return new Response(null, { status: 404 });
  const response = await apiDownload(`/admin/central-nfe/${encodeURIComponent(id)}/${kind.path}`);
  if (!response.ok) {
    return new Response("Não foi possível baixar o arquivo. Volte à nota e tente de novo.", {
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
