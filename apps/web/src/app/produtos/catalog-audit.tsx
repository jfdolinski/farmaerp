import styles from "../terminais/page.module.css";

export interface CatalogEvent {
  id: string;
  kind: "search" | "lookup" | "linked" | "changed" | "unlinked";
  source: "manual" | "barcode" | "import" | null;
  query: string | null;
  result_count: number | null;
  catalog_name: string | null;
  previous_catalog_name: string | null;
  user_name: string | null;
  occurred_at: string;
}

const SOURCES: Record<string, string> = {
  manual: "escolhido na busca",
  barcode: "pelo código de barras",
  import: "na importação de notas",
};

const when = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

const plural = (count: number, one: string, many: string) =>
  `${count.toLocaleString("pt-BR")} ${count === 1 ? one : many}`;

function describe(event: CatalogEvent): { what: string; detail: string } {
  const count = event.result_count ?? 0;
  switch (event.kind) {
    case "search":
      return {
        what: `Busca manual por “${event.query}”`,
        detail: plural(count, "item encontrado", "itens encontrados"),
      };
    case "lookup":
      return {
        what: `Busca automática pelo código ${event.query}`,
        detail:
          count === 0
            ? "Não está no Catálogo"
            : count === 1
              ? `Encontrado: ${event.catalog_name ?? "item do Catálogo"}`
              : plural(count, "item", "itens"),
      };
    case "linked":
      return { what: `Vinculado a ${event.catalog_name}`, detail: SOURCES[event.source ?? ""] ?? "" };
    case "changed":
      return {
        what: `Vínculo trocado para ${event.catalog_name}`,
        detail: `Antes: ${event.previous_catalog_name} · ${SOURCES[event.source ?? ""] ?? ""}`,
      };
    case "unlinked":
      return { what: "Vínculo desfeito", detail: `Era ${event.previous_catalog_name}` };
  }
}

/** Auditoria do Catálogo no produto, do mais novo para o mais antigo. */
export function CatalogAudit({ events }: { events: CatalogEvent[] }) {
  if (events.length === 0) {
    return <p className={styles.hint}>Nenhuma interação com o Catálogo registrada.</p>;
  }
  return (
    <div className={styles.tableWrap}>
      <table>
        <thead>
          <tr>
            <th>Quando</th>
            <th>O que aconteceu</th>
            <th>Quem</th>
          </tr>
        </thead>
        <tbody>
          {events.map((event) => {
            const { what, detail } = describe(event);
            return (
              <tr key={event.id}>
                <td>{when(event.occurred_at)}</td>
                <td>
                  {what}
                  {detail && <small>{detail}</small>}
                </td>
                <td>{event.user_name ?? "Sistema"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
