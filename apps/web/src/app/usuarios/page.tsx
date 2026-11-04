import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import {
  BranchOption,
  CreateUserForm,
  EditUser,
  TemporaryPassword,
  UserBranches,
  UserRow,
} from "./ui";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Usuários · FarmaERP" };

export default function UsersPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando usuários...</p>}>
        <UsersContent />
      </Suspense>
    </main>
  );
}

async function UsersContent() {
  const user = await requireUser("/usuarios");
  if (!user.isAdmin) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Usuários</h1>
        <section className={styles.card}>
          <p>Só administradores podem gerenciar usuários.</p>
        </section>
      </>
    );
  }

  const [users, branches] = await Promise.all([
    apiFetch<UserRow[]>("/admin/users"),
    apiFetch<BranchOption[]>("/admin/branches"),
  ]);
  if (!users.ok) redirectIfNeeded(users.error, "/usuarios");

  const branchList = branches.ok ? branches.data : [];
  const branchName = new Map(branchList.map((branch) => [branch.id, branch.name]));

  return (
    <>
      <AppHeader user={user} />
      <h1>Usuários</h1>
      <CreateUserForm />
      <section className={styles.card}>
        <h2>Usuários do grupo</h2>
        {!users.ok && <ErrorNotice error={users.error} />}
        {users.ok && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Código</th>
                  <th>Nome</th>
                  <th>Papel</th>
                  <th>Situação</th>
                  <th>Filiais</th>
                  <th>Ações</th>
                </tr>
              </thead>
              <tbody>
                {users.data.map((row) => (
                  <tr key={row.id}>
                    <td>{row.code}</td>
                    <td>
                      <strong>{row.name}</strong>
                      <small>{row.email ?? "Sem e-mail"}</small>
                    </td>
                    <td>{row.is_group_admin ? "Administrador" : "Usuário"}</td>
                    <td>
                      <span
                        className={`${styles.badge} ${row.is_active ? styles.active : styles.offline}`}
                      >
                        {row.is_active ? "Ativo" : "Inativo"}
                      </span>
                      <small>
                        {row.has_access ? "Acessa a retaguarda" : "Sem acesso à retaguarda"}
                      </small>
                    </td>
                    <td>
                      {row.is_group_admin
                        ? "Todas"
                        : row.branch_ids
                            .map((id) => branchName.get(id) ?? "Filial")
                            .join(", ") || "Nenhuma"}
                    </td>
                    <td className={styles.actions}>
                      <EditUser user={row} />
                      <UserBranches user={row} branches={branchList} />
                      {row.is_active && <TemporaryPassword user={row} />}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
