import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { CustomerGroupSelect } from "../../descontos/ui";
import { CreditSection } from "../../crediario/section";
import { CashbackSection } from "../../cashback/section";
import { CustomerHistorySection } from "../history";
import { CHANNELS, documentText, PURPOSES } from "../format";
import {
  AgreementRow,
  ConsentForm,
  ConsentRow,
  CustomerAgreementForm,
  CustomerAgreementRow,
  CustomerValues,
  DependentForm,
  DependentRow,
  EditCustomerForm,
} from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Cliente · FarmaERP" };

interface CustomerDetail extends CustomerValues {
  id: string;
  customer_group_id: string | null;
  code: string;
  person_type: string;
  document: string;
  name: string;
  dependents: DependentRow[];
  agreements: CustomerAgreementRow[];
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
  const canAgree = can(user, "agreements.manage");
  const agreements = canAgree ? await apiFetch<AgreementRow[]>("/admin/agreements") : null;
  const groups = await apiFetch<{ id: string; name: string }[]>("/admin/customer-groups");
  const available = agreements?.ok
    ? agreements.data.filter((agreement) => !customer.agreements.some((link) => link.agreement_id === agreement.id))
    : [];

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
        <h2>Compras</h2>
        <CustomerHistorySection customerId={customer.id} canSeeSales={can(user, "sales.view")} />
        {can(user, "sales.view") && (
          <p className={styles.hint}>
            <Link href={`/vendas-importadas?cliente=${customer.id}`}>Ver todas as vendas importadas deste cliente</Link>
          </p>
        )}
      </section>

      <section className={styles.card}>
        <h2>Grupo de clientes</h2>
        <p className={styles.hint}>Usado nos descontos por grupo. Os grupos ficam em Descontos.</p>
        <CustomerGroupSelect
          customerId={customer.id}
          current={customer.customer_group_id}
          groups={groups?.ok ? groups.data : []}
          canManage={canManage}
        />
      </section>

      <section className={styles.card}>
        <h2>Dependentes</h2>
        {customer.dependents.length === 0 && <p className={styles.hint}>Nenhum dependente.</p>}
        {customer.dependents.map((dependent) => (
          <DependentForm key={dependent.id} customerId={customer.id} dependent={dependent} canManage={canManage} />
        ))}
        {canManage && <DependentForm customerId={customer.id} canManage={canManage} />}
      </section>

      {can(user, "credit.view") && <CreditSection customerId={customer.id} />}

      <CashbackSection customerId={customer.id} />

      <section className={styles.card}>
        <h2>Convênios</h2>
        {customer.agreements.length === 0 && <p className={styles.hint}>Sem convênio.</p>}
        {customer.agreements.map((link) => (
          <CustomerAgreementForm key={link.id} customerId={customer.id} link={link} agreements={[]} canManage={canAgree} />
        ))}
        {canAgree && available.length > 0 && (
          <CustomerAgreementForm customerId={customer.id} agreements={available} canManage={canAgree} />
        )}
        {canAgree && agreements?.ok && agreements.data.length === 0 && (
          <p className={styles.hint}>
            Nenhum convênio cadastrado. <Link href="/convenios">Cadastrar convênios</Link>.
          </p>
        )}
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
