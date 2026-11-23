import { apiDownload } from "@/lib/api";

/** Repassa o XML da nota de serviço da API, com a sessão de quem pediu. */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const response = await apiDownload(`/admin/service-invoices/${encodeURIComponent(id)}/xml`);
  if (!response.ok) {
    return new Response("Não foi possível baixar o XML. Volte à nota e tente de novo.", {
      status: response.status,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return new Response(await response.text(), {
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      "Content-Disposition": response.headers.get("content-disposition") ?? 'attachment; filename="NFSe.xml"',
    },
  });
}
