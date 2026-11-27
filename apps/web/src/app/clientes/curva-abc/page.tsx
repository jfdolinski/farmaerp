import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { AbcSettingRow, AbcSettingsForm, RecalculateButton } from "./ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Curva ABC · FarmaERP" };

interface AbcCustomer {
  customer_id: string;
  code: number;
  name: string;
  curve: string;
  sales_count: number;
  calculated_at: string;
}

type Search = Promise<{ filial?: string; curva?: string; q?: string }>;

const when = (value: string | null) =>
  value ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" }) : "ainda não";

export default function AbcPage({ searchParams }: { searchParams: Search }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando a curva ABC...</p>}>
        <AbcContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function AbcContent({ searchParams }: { searchParams: Search }) {
  const user = await requireUser("/clientes/curva-abc");
  if (!can(user, "customers.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Curva ABC de clientes</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver clientes.</p>
        </section>
      </>
    );
  }
  const { filial, curva, q } = await searchParams;
  const settings = await apiFetch<AbcSettingRow[]>("/admin/abc/settings");
  if (!settings.ok) redirectIfNeeded(settings.error, "/clientes/curva-abc");
  const branches = settings.ok ? settings.data : [];
  const selected = branches.find((row) => row.branch_id === filial) ?? branches[0];
  const curve = curva === "A" || curva === "B" || curva === "C" ? curva : "A";
  const params = new URLSearchParams({ branch: selected?.branch_id ?? "", curve });
  if (q?.trim()) params.set("q", q.trim());
  const customers = selected ? await apiFetch<AbcCustomer[]>(`/admin/abc/customers?${params.toString()}`) : null;

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Curva ABC de clientes</h1>
        <Link href="/clientes">Voltar para clientes</Link>
      </div>
      <p className={styles.hint}>
        Conta as vendas de cada cliente na filial no período (as do PDV e as importadas do sistema anterior; canceladas não
        contam). A curva A vai a partir de um número de vendas, a B a partir de outro, e a C é o resto. Cada curva é
        recalculada no seu intervalo: na vez dela, entram os clientes que agora se encaixam e saem, para a curva certa, os
        que não se encaixam mais. O caixa mostra a curva ao identificar o cliente.
      </p>
      {!settings.ok && <ErrorNotice error={settings.error} />}
      {branches.length > 1 && (
        <form action="/clientes/curva-abc" className={styles.inline}>
          <label>
            Filial
            <select name="filial" defaultValue={selected?.branch_id}>
              {branches.map((row) => (
                <option key={row.branch_id} value={row.branch_id}>
                  {row.branch_name}
                </option>
              ))}
            </select>
          </label>
          <button type="submit">Ver</button>
        </form>
      )}
      {selected && (
        <>
          <section className={styles.card}>
            <h2>{selected.branch_name}</h2>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Curva</th>
                    <th>Regra</th>
                    <th>Clientes</th>
                    <th>Recalcula a cada</th>
                    <th>Último recálculo</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>A</td>
                    <td>{selected.a_min_sales} vendas ou mais</td>
                    <td>{selected.a_count}</td>
                    <td>{selected.a_interval_days} dias</td>
                    <td>{when(selected.a_ran_at)}</td>
                  </tr>
                  <tr>
                    <td>B</td>
                    <td>
                      de {selected.b_min_sales} a {selected.a_min_sales - 1} vendas
                    </td>
                    <td>{selected.b_count}</td>
                    <td>{selected.b_interval_days} dias</td>
                    <td>{when(selected.b_ran_at)}</td>
                  </tr>
                  <tr>
                    <td>C</td>
                    <td>menos de {selected.b_min_sales} vendas</td>
                    <td>{selected.c_count}</td>
                    <td>{selected.c_interval_days} dias</td>
                    <td>{when(selected.c_ran_at)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p className={styles.hint}>Período: últimos {selected.period_days} dias.</p>
            {selected.can_manage && (
              <>
                <RecalculateButton branchId={selected.branch_id} />
                <details className={styles.reason}>
                  <summary>Trocar os parâmetros</summary>
                  <AbcSettingsForm row={selected} />
                </details>
              </>
            )}
          </section>

          <section className={styles.card}>
            <h2>Clientes da curva {curve}</h2>
            <form action="/clientes/curva-abc" className={styles.inline}>
              <input type="hidden" name="filial" value={selected.branch_id} />
              <label>
                Curva
                <select name="curva" defaultValue={curve}>
                  <option value="A">A</option>
                  <option value="B">B</option>
                  <option value="C">C</option>
                </select>
              </label>
              <label>
                Buscar
                <input name="q" type="search" maxLength={100} defaultValue={q ?? ""} placeholder="Nome ou código" />
              </label>
              <button type="submit">Ver</button>
            </form>
            {customers && !customers.ok && <ErrorNotice error={customers.error} />}
            {customers?.ok && customers.data.length === 0 && <p className={styles.hint}>Nenhum cliente nesta curva.</p>}
            {customers?.ok && customers.data.length > 0 && (
              <div className={styles.tableWrap}>
                <table>
                  <thead>
                    <tr>
                      <th>Código</th>
                      <th>Cliente</th>
                      <th>Vendas no período</th>
                      <th>Calculado em</th>
                    </tr>
                  </thead>
                  <tbody>
                    {customers.data.map((row) => (
                      <tr key={row.customer_id}>
                        <td>{row.code}</td>
                        <td>
                          <Link href={`/clientes/${row.customer_id}`}>{row.name}</Link>
                        </td>
                        <td>{row.sales_count}</td>
                        <td>{when(row.calculated_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {customers?.ok && customers.data.length === 500 && <p className={styles.hint}>Mostrando os 500 com mais vendas.</p>}
          </section>
        </>
      )}
    </>
  );
}
