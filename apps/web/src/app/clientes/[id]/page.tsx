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
import { activeTab, TabItem, Tabs } from "../../shell/tabs";

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
type SearchParams = Promise<{ aba?: string | string[] }>;

const moment = (value: string) =>
  new Date(value).toLocaleString("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "America/Sao_Paulo",
  });

export default function CustomerPage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando cliente...</p>}>
        <CustomerContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function CustomerContent({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
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
  const tabs: TabItem[] = [
    { id: "cadastro", label: "Cadastro" },
    { id: "compras", label: "Compras" },
    { id: "credito", label: can(user, "credit.view") ? "Crediário e cashback" : "Cashback" },
    { id: "convenios", label: "Convênios", count: customer.agreements.length },
    { id: "dependentes", label: "Dependentes", count: customer.dependents.length },
    { id: "lgpd", label: "Consentimentos" },
  ];
  const tab = activeTab(tabs, (await searchParams).aba);
  const [agreements, groups, curves] = await Promise.all([
    tab === "convenios" && canAgree ? apiFetch<AgreementRow[]>("/admin/agreements") : null,
    tab === "cadastro" ? apiFetch<{ id: string; name: string }[]>("/admin/customer-groups") : null,
    tab === "compras"
      ? apiFetch<
          { branch_id: string; branch_name: string; curve: string; sales_count: number; calculated_at: string }[]
        >(`/admin/abc/customers/${encodeURIComponent(customer.id)}`)
      : null,
  ]);
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

      <Tabs base={path} items={tabs} active={tab}>
        {tab === "cadastro" && (
          <>
            <section className={styles.card}>
              <h2>Cadastro</h2>
              <p className={styles.hint}>
                {customer.person_type === "company" ? "Pessoa jurídica" : "Pessoa física"} ·{" "}
                {documentText(customer.document)}
              </p>
              <EditCustomerForm values={customer} canManage={canManage} />
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
          </>
        )}

        {tab === "compras" && curves && (
          <>
            <section className={styles.card}>
              <h2>Compras</h2>
              <CustomerHistorySection customerId={customer.id} canSeeSales={can(user, "sales.view")} />
              {can(user, "sales.view") && (
                <p className={styles.hint}>
                  <Link href={`/vendas-importadas?cliente=${customer.id}`}>
                    Ver todas as vendas importadas deste cliente
                  </Link>
                </p>
              )}
            </section>

            <section className={styles.card}>
              <h2>Curva ABC</h2>
              {!curves.ok && <ErrorNotice error={curves.error} />}
              {curves.ok && curves.data.length === 0 && (
                <p className={styles.hint}>
                  Ainda sem curva: o cliente entra na curva da filial no próximo recálculo depois da primeira compra.
                </p>
              )}
              {curves.ok && curves.data.length > 0 && (
                <ul className={styles.bullets}>
                  {curves.data.map((row) => (
                    <li key={row.branch_id}>
                      {row.branch_name}: <strong>curva {row.curve}</strong> ({row.sales_count}{" "}
                      {row.sales_count === 1 ? "venda" : "vendas"} no período, calculado em {moment(row.calculated_at)})
                    </li>
                  ))}
                </ul>
              )}
              <p className={styles.hint}>
                <Link href="/clientes/curva-abc">Ver a curva ABC da filial</Link>
              </p>
            </section>
          </>
        )}

        {tab === "dependentes" && (
          <section className={styles.card}>
            <h2>Dependentes</h2>
            {customer.dependents.length === 0 && <p className={styles.hint}>Nenhum dependente.</p>}
            {customer.dependents.map((dependent) => (
              <DependentForm key={dependent.id} customerId={customer.id} dependent={dependent} canManage={canManage} />
            ))}
            {canManage && <DependentForm customerId={customer.id} canManage={canManage} />}
          </section>
        )}

        {tab === "credito" && (
          <>
            {can(user, "credit.view") && <CreditSection customerId={customer.id} />}
            <CashbackSection customerId={customer.id} />
          </>
        )}

        {tab === "convenios" && (
          <section className={styles.card}>
            <h2>Convênios</h2>
            {customer.agreements.length === 0 && <p className={styles.hint}>Sem convênio.</p>}
            {customer.agreements.map((link) => (
              <CustomerAgreementForm
                key={link.id}
                customerId={customer.id}
                link={link}
                agreements={[]}
                canManage={canAgree}
              />
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
        )}

        {tab === "lgpd" && (
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
        )}
      </Tabs>
    </>
  );
}
