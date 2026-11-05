import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { CHANNELS, documentText, PURPOSES } from "../format";
import {
  ConsentForm,
  ConsentRow,
  CustomerValues,
  DependentForm,
  DependentRow,
  EditCustomerForm,
} from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Cliente · FarmaERP" };

interface CustomerDetail extends CustomerValues {
  id: string;
  code: string;
  person_type: string;
  document: string;
  name: string;
  dependents: DependentRow[];
  consents: ConsentRow[];
  consent_history: {
    purpose: string;
    granted: boolean;
    channel: string;
    created_at: string;
    author: string | null;
  }[];
}

type Params = Promise<{ id: string }>;

const moment = (value: string) =>
  new Date(value).toLocaleString("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "America/Sao_Paulo",
  });

export default function CustomerPage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando cliente...</p>}>
        <CustomerContent params={params} />
      </Suspense>
    </main>
  );
}

async function CustomerContent({ params }: { params: Params }) {
  const { id } = await params;
  const path = `/clientes/${id}`;
  const user = await requireUser(path);
  const canManage = can(user, "customers.manage");

  if (!can(user, "customers.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Cliente</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os clientes.</p>
        </section>
      </>
    );
  }

  const result = await apiFetch<CustomerDetail>(`/admin/customers/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Cliente</h1>
        <ErrorNotice error={result.error} />
        <Link href="/clientes">Voltar para clientes</Link>
      </>
    );
  }
  const customer = result.data;

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>
          {customer.code} · {customer.name}
        </h1>
        <Link href="/clientes">Voltar para clientes</Link>
      </div>

      <section className={styles.card}>
        <h2>Cadastro</h2>
        <p className={styles.hint}>
          {customer.person_type === "company" ? "Pessoa jurídica" : "Pessoa física"} ·{" "}
          {documentText(customer.document)}
        </p>
        <EditCustomerForm values={customer} canManage={canManage} />
      </section>

      <section className={styles.card}>
        <h2>Dependentes</h2>
        {customer.dependents.length === 0 && <p className={styles.hint}>Nenhum dependente.</p>}
        {customer.dependents.map((dependent) => (
          <DependentForm key={dependent.id} customerId={customer.id} dependent={dependent} canManage={canManage} />
        ))}
        {canManage && <DependentForm customerId={customer.id} canManage={canManage} />}
      </section>

      <section className={styles.card}>
        <h2>Consentimentos (LGPD)</h2>
        <p className={styles.hint}>Registre a decisão que o próprio cliente informou, e por qual canal.</p>
        {customer.consents.map((consent) => (
          <ConsentForm key={consent.purpose} customerId={customer.id} consent={consent} canManage={canManage} />
        ))}
        <details className={styles.reason}>
          <summary>Histórico de consentimentos</summary>
          {customer.consent_history.length === 0 && <p className={styles.hint}>Nenhuma decisão registrada.</p>}
          {customer.consent_history.length > 0 && (
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Quando</th>
                    <th>Finalidade</th>
                    <th>Decisão</th>
                    <th>Canal</th>
                    <th>Registrado por</th>
                  </tr>
                </thead>
                <tbody>
                  {customer.consent_history.map((event, index) => (
                    <tr key={index}>
                      <td>{moment(event.created_at)}</td>
                      <td>{PURPOSES[event.purpose] ?? event.purpose}</td>
                      <td>{event.granted ? "Autorizou" : "Revogou"}</td>
                      <td>{CHANNELS[event.channel] ?? event.channel}</td>
                      <td>{event.author}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </details>
      </section>
    </>
  );
}
