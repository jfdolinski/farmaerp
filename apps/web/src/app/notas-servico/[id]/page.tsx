import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import {
  competenceText,
  dateTimeText,
  documentText,
  ISS_WITHHOLDING_LABELS,
  moneyText,
  PIS_COFINS_WITHHOLDING_LABELS,
  SERVICE_STATUS_LABELS,
} from "../format";

export const metadata: Metadata = { title: "Nota de serviço · FarmaERP" };

interface ServiceInvoiceDetail {
  id: string;
  branch_name: string;
  access_key: string;
  number: string;
  environment: number;
  issued_at: string;
  competence: string;
  processed_at: string | null;
  provider_document: string | null;
  provider_name: string;
  provider_location: string | null;
  taker_document: string | null;
  service_code: string | null;
  municipal_code: string | null;
  nbs_code: string | null;
  description: string;
  incidence_location: string | null;
  service_value: string;
  unconditional_discount: string;
  deductions: string;
  iss_base: string | null;
  iss_rate: string | null;
  iss_value: string;
  iss_withholding: number | null;
  irrf_withheld: string;
  csll_withheld: string;
  social_security_withheld: string;
  pis_value: string;
  cofins_value: string;
  pis_cofins_withholding: number | null;
  total_withheld: string;
  net_value: string;
  status: string;
  status_changed_at: string | null;
  replaced_by: string | null;
  replaced_by_number: string | null;
  replaces_id: string | null;
  replaces_number: string | null;
}

type Params = Promise<{ id: string }>;

export default function ServiceInvoicePage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando nota de serviço...</p>}>
        <ServiceInvoiceContent params={params} />
      </Suspense>
    </main>
  );
}

async function ServiceInvoiceContent({ params }: { params: Params }) {
  const { id } = await params;
  const path = `/notas-servico/${id}`;
  const user = await requireUser(path);
  if (!can(user, "purchases.view") && !can(user, "purchases.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Nota de serviço</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as notas de serviço.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ServiceInvoiceDetail>(`/admin/service-invoices/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Nota de serviço</h1>
        <ErrorNotice error={result.error} />
        <Link href="/notas-servico">Voltar para notas de serviço</Link>
      </>
    );
  }
  const note = result.data;
  const retentions: [string, string][] = [
    ["IRRF", note.irrf_withheld],
    ["CSLL", note.csll_withheld],
    ["INSS (contribuição previdenciária)", note.social_security_withheld],
    ["PIS", note.pis_value],
    ["COFINS", note.cofins_value],
  ];

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Nota de serviço {note.number}</h1>
        <Link href="/notas-servico">Voltar para notas de serviço</Link>
      </div>
      <section className={styles.card}>
        <h2>{note.provider_name}</h2>
        <p className={styles.hint}>
          {documentText(note.provider_document)}
          {note.provider_location && ` · ${note.provider_location}`} · Para {note.branch_name} · Emitida em{" "}
          {dateTimeText(note.issued_at)} · Competência {competenceText(note.competence)}
        </p>
        {note.environment === 2 && (
          <p className={styles.warning}>Nota do ambiente de testes do Ambiente Nacional.</p>
        )}
        <p>
          <strong className={note.status === "active" ? undefined : styles.warning}>
            {SERVICE_STATUS_LABELS[note.status] ?? note.status}
          </strong>
          {note.status_changed_at && ` em ${dateTimeText(note.status_changed_at)}`}
          {note.replaced_by && (
            <>
              {" "}
              pela nota <Link href={`/notas-servico/${note.replaced_by}`}>{note.replaced_by_number}</Link>
            </>
          )}
        </p>
        {note.replaces_id && (
          <p className={styles.hint}>
            Esta nota substitui a nota <Link href={`/notas-servico/${note.replaces_id}`}>{note.replaces_number}</Link>.
          </p>
        )}
        <p className={styles.hint}>Chave {note.access_key}</p>
        <p>
          <a href={`/notas-servico/${note.id}/xml`} download>
            Baixar XML
          </a>
        </p>
      </section>

      <section className={styles.card}>
        <h2>Serviço</h2>
        <p>{note.description}</p>
        <p className={styles.hint}>
          {[
            note.service_code && `Código nacional ${note.service_code}`,
            note.municipal_code && `Código municipal ${note.municipal_code}`,
            note.nbs_code && `NBS ${note.nbs_code}`,
            note.incidence_location && `ISS devido em ${note.incidence_location}`,
          ]
            .filter(Boolean)
            .join(" · ")}
        </p>
      </section>

      <section className={styles.card}>
        <h2>Valores</h2>
        <div className={styles.tableWrap}>
          <table>
            <tbody>
              <tr>
                <th scope="row">Valor do serviço</th>
                <td>{moneyText(note.service_value)}</td>
              </tr>
              {Number(note.unconditional_discount) > 0 && (
                <tr>
                  <th scope="row">Desconto incondicionado</th>
                  <td>{moneyText(note.unconditional_discount)}</td>
                </tr>
              )}
              {Number(note.deductions) > 0 && (
                <tr>
                  <th scope="row">Deduções</th>
                  <td>{moneyText(note.deductions)}</td>
                </tr>
              )}
              <tr>
                <th scope="row">
                  ISS{note.iss_rate !== null && ` (${Number(note.iss_rate).toLocaleString("pt-BR")}%)`}
                </th>
                <td>
                  {moneyText(note.iss_value)}
                  {note.iss_withholding !== null && (
                    <small className={styles.hint}> {ISS_WITHHOLDING_LABELS[note.iss_withholding]}</small>
                  )}
                </td>
              </tr>
              {retentions
                .filter(([, value]) => Number(value) > 0)
                .map(([label, value]) => (
                  <tr key={label}>
                    <th scope="row">{label}</th>
                    <td>{moneyText(value)}</td>
                  </tr>
                ))}
              <tr>
                <th scope="row">Total retido</th>
                <td>{moneyText(note.total_withheld)}</td>
              </tr>
              <tr>
                <th scope="row">Valor líquido</th>
                <td>
                  <strong>{moneyText(note.net_value)}</strong>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        {note.pis_cofins_withholding !== null && (
          <p className={styles.hint}>{PIS_COFINS_WITHHOLDING_LABELS[note.pis_cofins_withholding]}</p>
        )}
        <p className={styles.hint}>
          Os valores são os da nota emitida pelo prestador. Quem retém imposto precisa recolhê-lo: confira com o contador.
        </p>
      </section>
    </>
  );
}
