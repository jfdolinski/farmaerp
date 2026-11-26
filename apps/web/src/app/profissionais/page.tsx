import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { ProfessionalForm, type ProfessionalRow } from "./ui";

export const metadata: Metadata = { title: "Profissionais da saúde · FarmaERP" };

type SearchParams = Promise<{ busca?: string; inativos?: string }>;

export default function ProfessionalsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando profissionais...</p>}>
        <ProfessionalsContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ProfessionalsContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/profissionais");
  const params = await searchParams;
  const search = (params.busca ?? "").trim().slice(0, 150);
  const inactive = params.inativos === "1";
  const canManage = can(user, "health_professionals.manage");

  if (!canManage && !can(user, "controlled.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Profissionais da saúde</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os profissionais da saúde.</p>
        </section>
      </>
    );
  }

  const query = new URLSearchParams();
  if (search) query.set("busca", search);
  if (inactive) query.set("inativos", "1");
  const result = await apiFetch<ProfessionalRow[]>(`/admin/health-professionals?${query.toString()}`);
  if (!result.ok) redirectIfNeeded(result.error, "/profissionais");
  const rows = result.ok ? result.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Profissionais da saúde</h1>
      <p className={styles.hint}>
        Prescritores da rede. O caixa busca por nome ou número no conselho ao lançar a receita do controlado, e pode
        cadastrar na hora quem ainda não está aqui. O mesmo conselho, número e UF não se repete.
      </p>
      {canManage && (
        <section className={styles.card}>
          <h2>Novo profissional</h2>
          <ProfessionalForm />
        </section>
      )}
      <section className={styles.card}>
        <form className={styles.inline} method="get">
          <label>
            Buscar por nome ou número
            <input name="busca" defaultValue={search} maxLength={150} />
          </label>
          <label className={styles.check}>
            <input type="checkbox" name="inativos" value="1" defaultChecked={inactive} />
            Mostrar inativos
          </label>
          <button type="submit">Buscar</button>
        </form>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && rows.length === 0 && (
          <p className={styles.hint}>{search ? "Nenhum profissional encontrado." : "Nenhum profissional cadastrado."}</p>
        )}
        {rows.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Nome</th>
                  <th>Registro</th>
                  <th>Especialidade</th>
                  <th>Situação</th>
                  {canManage && <th />}
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td>{row.name}</td>
                    <td>
                      {row.council} {row.registration}/{row.state}
                    </td>
                    <td>{row.specialty ?? "—"}</td>
                    <td>{row.active ? "Ativo" : "Inativo"}</td>
                    {canManage && (
                      <td>
                        <details>
                          <summary>Editar</summary>
                          <ProfessionalForm row={row} />
                        </details>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {rows.length === 500 && <p className={styles.hint}>Mostrando os 500 primeiros. Refine a busca.</p>}
      </section>
    </>
  );
}
