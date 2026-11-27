import { apiDownload } from "@/lib/api";

/** Repassa o DANFE A4 da NF-e de venda (modelo 55) autorizada, com a sessão de quem pediu. */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const response = await apiDownload(`/admin/fiscal-documents/${encodeURIComponent(id)}/danfe`);
  if (!response.ok) {
    return new Response("Não foi possível gerar o DANFE. Volte às notas fiscais e tente de novo.", {
      status: response.status,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return new Response(await response.arrayBuffer(), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": response.headers.get("content-disposition") ?? 'attachment; filename="DANFE.pdf"',
    },
  });
}
