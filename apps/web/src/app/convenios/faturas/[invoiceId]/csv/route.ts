import { apiFetch } from "@/lib/api";
import { InvoiceDetail, itemLabel, momentText } from "../../../format";

/** Texto da célula: aspas escapadas e sem virar fórmula na planilha. */
function cell(value: string | null | undefined): string {
  let text = value ?? "";
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}

/** Marca de UTF-8 para a planilha abrir os acentos certos. */
const BOM = String.fromCharCode(0xfeff);

/** Valor com vírgula decimal, como a planilha em português espera. */
const amount = (value: number) => Number(value).toFixed(2).replace(".", ",");

/** Fatura do convênio em CSV (separado por ponto e vírgula), com a sessão de quem pediu. */
export async function GET(_request: Request, { params }: { params: Promise<{ invoiceId: string }> }) {
  const { invoiceId } = await params;
  const result = await apiFetch<InvoiceDetail>(`/admin/agreement-invoices/${encodeURIComponent(invoiceId)}`);
  if (!result.ok) {
    return new Response("Não foi possível baixar a fatura. Volte à fatura e tente de novo.", {
      status: 404,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  const invoice = result.data;
  const lines = [
    ["Data", "Cliente", "Matrícula", "Lançamento", "Valor"].map(cell).join(";"),
    ...invoice.items.map((item) =>
      [cell(momentText(item.occurred_at)), cell(item.customer_name), cell(item.registration), cell(itemLabel(item)), amount(item.amount)].join(";"),
    ),
    ["", "", "", cell("Total"), amount(invoice.total)].join(";"),
  ];
  const name = `fatura-convenio-${invoice.period_end}.csv`;
  return new Response(`${BOM}${lines.join("\r\n")}\r\n`, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${name}"`,
    },
  });
}
