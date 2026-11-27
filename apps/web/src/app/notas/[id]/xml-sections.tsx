import styles from "../../terminais/page.module.css";
import { cnpjText } from "../../fornecedores/format";
import { dateTimeText, dayText, moneyText, quantityText } from "../format";

// Seções do detalhe da nota que vêm do XML guardado (infNFe lida pela API), das duplicatas e da
// auditoria. O XML chega como objeto: atributos com o prefixo @_, e grupos repetidos podem vir como
// lista ou, quando há um só, como objeto.

type Node = Record<string, unknown>;

export interface Installment {
  line: number;
  number: string | null;
  due_date: string | null;
  amount: number;
}

export interface AuditEntry {
  kind: string;
  detail: Record<string, unknown>;
  user_name: string | null;
  occurred_at: string;
}

const node = (value: unknown): Node | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Node) : undefined;
const list = (value: unknown): Node[] =>
  (Array.isArray(value) ? value : value === undefined || value === null ? [] : [value]).filter(
    (entry): entry is Node => node(entry) !== undefined,
  );
/** Texto no caminho (a.b.c), ou vazio. */
const pick = (root: unknown, path: string): string | null => {
  let current: unknown = root;
  for (const part of path.split(".")) current = node(current)?.[part];
  return typeof current === "string" && current !== "" ? current : null;
};
/** O único grupo dentro do nó (ex.: ICMS00, ICMS10... dentro de ICMS). */
const onlyGroup = (value: unknown): Node | undefined => {
  const groups = Object.values(node(value) ?? {}).filter((entry) => node(entry));
  return groups.length === 1 ? node(groups[0]) : undefined;
};
const join = (parts: (string | null | false | undefined)[], separator = " · ") => parts.filter(Boolean).join(separator);
const money = (value: string | null) => (value === null ? null : moneyText(value));

const FREIGHT: Record<string, string> = {
  "0": "Por conta do emitente (CIF)",
  "1": "Por conta do destinatário (FOB)",
  "2": "Por conta de terceiros",
  "3": "Transporte próprio do remetente",
  "4": "Transporte próprio do destinatário",
  "9": "Sem frete",
};
const PAYMENT: Record<string, string> = {
  "01": "Dinheiro",
  "02": "Cheque",
  "03": "Cartão de crédito",
  "04": "Cartão de débito",
  "05": "Crédito da loja",
  "10": "Vale alimentação",
  "11": "Vale refeição",
  "12": "Vale presente",
  "13": "Vale combustível",
  "15": "Boleto",
  "16": "Depósito",
  "17": "PIX",
  "18": "Transferência",
  "19": "Programa de fidelidade",
  "90": "Sem pagamento",
  "99": "Outros",
};
const REGIME: Record<string, string> = {
  "1": "Simples Nacional",
  "2": "Simples Nacional com excesso de sublimite",
  "3": "Regime normal",
  "4": "MEI",
};
const ORIGIN: Record<string, string> = {
  "0": "Nacional",
  "1": "Estrangeira, importação direta",
  "2": "Estrangeira, adquirida no mercado interno",
  "3": "Nacional, mais de 40% de conteúdo estrangeiro",
  "4": "Nacional, processo produtivo básico",
  "5": "Nacional, até 40% de conteúdo estrangeiro",
  "6": "Estrangeira, importação direta sem similar",
  "7": "Estrangeira, mercado interno sem similar",
  "8": "Nacional, mais de 70% de conteúdo estrangeiro",
};

function address(value: unknown): string {
  return join(
    [
      join([pick(value, "xLgr"), pick(value, "nro"), pick(value, "xCpl")], ", "),
      pick(value, "xBairro"),
      join([pick(value, "xMun"), pick(value, "UF")], " - "),
      pick(value, "CEP") && `CEP ${(pick(value, "CEP") as string).replace(/^(\d{5})(\d{3})$/, "$1-$2")}`,
    ],
    " · ",
  );
}

function document(value: unknown): string | null {
  const cnpj = pick(value, "CNPJ");
  if (cnpj) return `CNPJ ${cnpjText(cnpj)}`;
  const cpf = pick(value, "CPF");
  return cpf ? "CPF informado" : null;
}

/** Título e linhas; sem nenhuma linha preenchida, não aparece. */
function Group({ title, rows }: { title: string; rows: [string, string | null][] }) {
  if (!rows.some(([, value]) => value)) return null;
  return (
    <>
      <h3>{title}</h3>
      <Rows rows={rows} />
    </>
  );
}

function Rows({ rows }: { rows: [string, string | null][] }) {
  const shown = rows.filter(([, value]) => value);
  if (shown.length === 0) return null;
  return (
    <div className={styles.tableWrap}>
      <table>
        <tbody>
          {shown.map(([label, value]) => (
            <tr key={label}>
              <th scope="row">{label}</th>
              <td>{value}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Situação da leitura do XML: ainda na fila, ou não foi possível ler. */
export function ContentNotice({ content, error }: { content: Node | null; error: string | null }) {
  if (content) return null;
  return error ? (
    <p className={styles.warning}>
      Não foi possível ler os dados completos do XML desta nota. Os dados principais, os itens e os lotes continuam
      valendo.
    </p>
  ) : (
    <p className={styles.hint}>Os dados completos do XML desta nota ainda estão sendo lidos. Volte em alguns minutos.</p>
  );
}

/** Dados gerais da nota: operação, emitente, destinatário, transporte, pagamento e informações adicionais. */
export function NoteDataSection({ content }: { content: Node }) {
  const ide = content.ide;
  const emit = content.emit;
  const dest = content.dest;
  const transp = content.transp;
  const carrier = node(transp)?.transporta;
  const volumes = list(node(transp)?.vol);
  const payments = list(node(content.pag)?.detPag);
  const totals = node(node(content.total)?.ICMSTot);
  const references = list(node(ide)?.NFref);
  return (
    <section className={styles.card}>
      <h2>Dados da nota</h2>
      <Rows
        rows={[
          ["Natureza da operação", pick(ide, "natOp")],
          ["Saída da mercadoria", pick(ide, "dhSaiEnt") && dateTimeText(pick(ide, "dhSaiEnt") as string)],
          [
            "Notas referenciadas",
            references.length > 0
              ? references.map((ref) => pick(ref, "refNFe") ?? "nota em papel ou de produtor").join(", ")
              : null,
          ],
        ]}
      />

      <Group
        title="Emitente"
        rows={[
          ["Razão social", pick(emit, "xNome")],
          ["Nome fantasia", pick(emit, "xFant")],
          ["Documento", document(emit)],
          ["Inscrição estadual", pick(emit, "IE")],
          ["Regime tributário", REGIME[pick(emit, "CRT") ?? ""] ?? null],
          ["Endereço", address(node(emit)?.enderEmit) || null],
          ["Telefone", pick(emit, "enderEmit.fone")],
        ]}
      />

      <Group
        title="Destinatário"
        rows={[
          ["Nome", pick(dest, "xNome")],
          ["Documento", document(dest)],
          ["Inscrição estadual", pick(dest, "IE")],
          ["Endereço", address(node(dest)?.enderDest) || null],
        ]}
      />

      <Group
        title="Transporte"
        rows={[
          ["Frete", FREIGHT[pick(transp, "modFrete") ?? ""] ?? null],
          ["Transportadora", join([pick(carrier, "xNome"), document(carrier)]) || null],
          ["Placa", pick(transp, "veicTransp.placa")],
          [
            "Volumes",
            volumes.length > 0
              ? volumes
                  .map((volume) =>
                    join([
                      pick(volume, "qVol") && `${pick(volume, "qVol")} ${pick(volume, "esp") ?? "volume(s)"}`,
                      pick(volume, "marca") && `marca ${pick(volume, "marca")}`,
                      pick(volume, "pesoL") && `peso líquido ${quantityText(pick(volume, "pesoL"))} kg`,
                      pick(volume, "pesoB") && `peso bruto ${quantityText(pick(volume, "pesoB"))} kg`,
                    ]),
                  )
                  .filter(Boolean)
                  .join("; ") || null
              : null,
          ],
        ]}
      />

      {payments.length > 0 && (
        <>
          <h3>Pagamento informado na nota</h3>
          <ul className={styles.bullets}>
            {payments.map((payment, index) => (
              <li key={index}>
                {PAYMENT[pick(payment, "tPag") ?? ""] ?? `Forma ${pick(payment, "tPag") ?? "não informada"}`}:{" "}
                {money(pick(payment, "vPag")) ?? "sem valor"}
                {pick(payment, "indPag") === "1" && " (a prazo)"}
              </li>
            ))}
          </ul>
        </>
      )}

      {totals && (
        <>
          <Group
            title="Totais de impostos"
            rows={[
              ["Base do ICMS", money(pick(totals, "vBC"))],
              ["ICMS", money(pick(totals, "vICMS"))],
              ["ICMS desonerado", money(pick(totals, "vICMSDeson"))],
              ["FCP", money(pick(totals, "vFCP"))],
              ["Base do ICMS ST", money(pick(totals, "vBCST"))],
              ["ICMS ST", money(pick(totals, "vST"))],
              ["FCP ST", money(pick(totals, "vFCPST"))],
              ["IPI", money(pick(totals, "vIPI"))],
              ["PIS", money(pick(totals, "vPIS"))],
              ["COFINS", money(pick(totals, "vCOFINS"))],
              ["Tributos aproximados", money(pick(totals, "vTotTrib"))],
            ].filter(([, value]) => value !== null && value !== moneyText("0")) as [string, string | null][]}
          />
        </>
      )}

      {(pick(content, "infAdic.infCpl") || pick(content, "infAdic.infAdFisco")) && (
        <>
          <h3>Informações adicionais</h3>
          {pick(content, "infAdic.infCpl") && <p className={styles.preformatted}>{pick(content, "infAdic.infCpl")}</p>}
          {pick(content, "infAdic.infAdFisco") && (
            <p className={styles.preformatted}>Do fisco: {pick(content, "infAdic.infAdFisco")}</p>
          )}
        </>
      )}
    </section>
  );
}

/** Item do XML pelo número (nItem). */
export function itemContent(content: Node | null, itemNumber: number): Node | undefined {
  if (!content) return undefined;
  return list(content.det).find((det) => pick(det, "@_nItem") === String(itemNumber));
}

/** Impostos e dados de medicamento de um item, como vieram no XML. */
export function ItemTaxes({ det }: { det: Node | undefined }) {
  if (!det) return null;
  const tax = node(det.imposto);
  const icms = onlyGroup(tax?.ICMS);
  const ipi = node(tax?.IPI);
  const ipiGroup = node(ipi?.IPITrib) ?? node(ipi?.IPINT);
  const pis = onlyGroup(tax?.PIS);
  const cofins = onlyGroup(tax?.COFINS);
  const med = node(node(det.prod)?.med);
  const rate = (group: Node | undefined, base: string, percent: string, value: string) =>
    join([
      money(pick(group, base)) && `base ${money(pick(group, base))}`,
      pick(group, percent) && `${quantityText(pick(group, percent))}%`,
      money(pick(group, value)) && `valor ${money(pick(group, value))}`,
    ]) || null;
  const rows: [string, string | null][] = [
    ["Origem", ORIGIN[pick(icms, "orig") ?? ""] ?? null],
    ["ICMS", join([pick(icms, "CST") && `CST ${pick(icms, "CST")}`, pick(icms, "CSOSN") && `CSOSN ${pick(icms, "CSOSN")}`, rate(icms, "vBC", "pICMS", "vICMS")]) || null],
    ["ICMS ST", rate(icms, "vBCST", "pICMSST", "vICMSST")],
    ["ICMS ST retido antes", rate(icms, "vBCSTRet", "pST", "vICMSSTRet")],
    ["FCP ST", money(pick(icms, "vFCPST"))],
    ["IPI", join([pick(ipiGroup, "CST") && `CST ${pick(ipiGroup, "CST")}`, rate(ipiGroup, "vBC", "pIPI", "vIPI")]) || null],
    ["PIS", join([pick(pis, "CST") && `CST ${pick(pis, "CST")}`, rate(pis, "vBC", "pPIS", "vPIS")]) || null],
    ["COFINS", join([pick(cofins, "CST") && `CST ${pick(cofins, "CST")}`, rate(cofins, "vBC", "pCOFINS", "vCOFINS")]) || null],
    ["Tributos aproximados", money(pick(tax, "vTotTrib"))],
    ["CEST", pick(det, "prod.CEST")],
    ["Registro na Anvisa", pick(med, "cProdANVISA")],
    ["Motivo da isenção na Anvisa", pick(med, "xMotivoIsencao")],
    ["PMC", money(pick(med, "vPMC"))],
    ["Pedido de compra", join([pick(det, "prod.xPed"), pick(det, "prod.nItemPed") && `item ${pick(det, "prod.nItemPed")}`]) || null],
    ["Informação do item", pick(det, "infAdProd")],
  ];
  if (rows.every(([, value]) => !value)) return null;
  return (
    <details className={styles.reason}>
      <summary>Impostos e dados do XML</summary>
      <Rows rows={rows} />
    </details>
  );
}

/** Financeiro da nota: as duplicatas da cobrança. */
export function InstallmentsSection({ installments, read }: { installments: Installment[]; read: boolean }) {
  const total = installments.reduce((sum, row) => sum + Number(row.amount), 0);
  return (
    <section className={styles.card}>
      <h2>Financeiro</h2>
      {!read && <p className={styles.hint}>As duplicatas aparecem quando os dados completos do XML forem lidos.</p>}
      {read && installments.length === 0 && <p className={styles.hint}>A nota não traz duplicatas (cobrança).</p>}
      {installments.length > 0 && (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Duplicata</th>
                <th>Vencimento</th>
                <th>Valor</th>
              </tr>
            </thead>
            <tbody>
              {installments.map((row) => (
                <tr key={row.line}>
                  <td>{row.number ?? row.line}</td>
                  <td>{row.due_date ? dayText(row.due_date) : "sem vencimento"}</td>
                  <td>{moneyText(row.amount)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <th scope="row" colSpan={2}>
                  Total
                </th>
                <td>
                  <strong>{moneyText(total)}</strong>
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}
    </section>
  );
}

export interface BatchRow {
  itemNumber: number;
  description: string;
  unit: string;
  number: string;
  quantity: number;
  manufacturedOn: string | null;
  expiresOn: string;
}

/** Todos os lotes da nota, item a item. */
export function BatchesSection({ rows }: { rows: BatchRow[] }) {
  return (
    <section className={styles.card}>
      <h2>Lotes</h2>
      {rows.length === 0 ? (
        <p className={styles.hint}>A nota não tem lotes.</p>
      ) : (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Item</th>
                <th>Lote</th>
                <th>Quantidade</th>
                <th>Fabricação</th>
                <th>Validade</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={`${row.itemNumber}-${row.number}`}>
                  <td>
                    {row.itemNumber}. {row.description}
                  </td>
                  <td>{row.number}</td>
                  <td>
                    {quantityText(row.quantity)} {row.unit}
                  </td>
                  <td>{row.manufacturedOn ? dayText(row.manufacturedOn) : ""}</td>
                  <td>{dayText(row.expiresOn)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

const text = (value: unknown) => (typeof value === "string" || typeof value === "number" ? String(value) : "");

/** Frase de cada registro da auditoria. */
export function auditText(entry: AuditEntry): string {
  const d = entry.detail;
  const item = d.item_number !== undefined ? `Item ${text(d.item_number)}` : "";
  switch (entry.kind) {
    case "posted":
      return "Nota lançada no estoque";
    case "reversed":
      return `Lançamento estornado${d.reason ? `: ${text(d.reason)}` : ""}`;
    case "linked":
      return d.previous_product
        ? `${item} trocado de ${text(d.previous_product)} para ${text(d.product)}`
        : `${item} ligado a ${text(d.product)}${d.source === "supplier_code" ? " (pelo código do fornecedor, depois da importação)" : d.source === "barcode" ? " (pelo código de barras, depois da importação)" : ""}`;
    case "unlinked":
      return `${item} desligado de ${text(d.previous_product)}`;
    case "batch_added":
      return `${item}: lote ${text(d.batch_number)} informado (${quantityText(text(d.quantity))}, validade ${dayText(text(d.expires_on))})`;
    case "batch_removed":
      return `${item}: lote ${text(d.batch_number)} ${d.source === "xml" ? "do XML trocado pelos digitados" : "tirado"}`;
    case "cost_released":
      return `${item}: custo liberado${d.reason ? ` (${text(d.reason)})` : ""}`;
    case "discarded":
      return `Nota descartada${d.reason ? `: ${text(d.reason)}` : ""}`;
    default:
      return entry.kind;
  }
}

/** Tudo o que aconteceu com a nota depois da importação, do mais novo para o mais antigo. */
export function AuditSection({ audit }: { audit: AuditEntry[] }) {
  return (
    <section className={styles.card}>
      <h2>Auditoria</h2>
      {audit.length === 0 ? (
        <p className={styles.hint}>Nenhuma alteração desde a importação.</p>
      ) : (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Quando</th>
                <th>O quê</th>
                <th>Quem</th>
              </tr>
            </thead>
            <tbody>
              {audit.map((entry, index) => (
                <tr key={index}>
                  <td>{dateTimeText(entry.occurred_at)}</td>
                  <td>{auditText(entry)}</td>
                  <td>{entry.user_name ?? "Sistema"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
