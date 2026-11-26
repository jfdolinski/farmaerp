import { apiDownload } from "@/lib/api";

/** Repassa o XML da NFC-e (ou o do cancelamento, com ?kind=cancel) com a sessão de quem pediu. */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const kind = new URL(request.url).searchParams.get("kind") === "cancel" ? "?kind=cancel" : "";
  const response = await apiDownload(`/admin/fiscal-documents/${encodeURIComponent(id)}/xml${kind}`);
  if (!response.ok) {
    return new Response("Não foi possível baixar o XML. Volte às notas fiscais e tente de novo.", {
      status: response.status,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return new Response(await response.text(), {
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      "Content-Disposition": response.headers.get("content-disposition") ?? 'attachment; filename="NFCe.xml"',
    },
  });
}
