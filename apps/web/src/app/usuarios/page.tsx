import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import {
  BranchOption,
  CreateUserForm,
  EditUser,
  RoleOption,
  PdvAuthMode,
  PdvPin,
  TemporaryPassword,
  UserBranches,
  UserRoles,
  UserRow,
} from "./ui";
import { AUTH_MODE_LABELS } from "../entradas-pdv/labels";
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
  const canManage = can(user, "users.manage");
  const canAssign = can(user, "roles.assign");
  const canReset = can(user, "users.reset_password");

  if (!can(user, "users.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Usuários</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os usuários.</p>
        </section>
      </>
    );
  }

  const [users, branches, roles] = await Promise.all([
    apiFetch<UserRow[]>("/admin/users"),
    apiFetch<BranchOption[]>("/admin/branches"),
    apiFetch<RoleOption[]>("/admin/roles"),
  ]);
  if (!users.ok) redirectIfNeeded(users.error, "/usuarios");

  const branchList = branches.ok ? branches.data : [];
  const roleList = roles.ok ? roles.data : [];
  const branchName = new Map(branchList.map((branch) => [branch.id, branch.name]));

  return (
    <>
      <AppHeader user={user} />
      <h1>Usuários</h1>
      {canManage && <CreateUserForm />}
      <section className={styles.card}>
        <h2>Usuários</h2>
        {!users.ok && <ErrorNotice error={users.error} />}
        {users.ok && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Código</th>
                  <th>Nome</th>
                  <th>Perfis</th>
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
                      <small>PDV: {AUTH_MODE_LABELS[row.pdv_auth_mode] ?? row.pdv_auth_mode}</small>
                    </td>
                    <td>
                      {row.roles.length === 0 && "Nenhum"}
                      {row.roles.map((role) => (
                        <small key={role.id}>
                          {role.name}
                          {role.branch_id &&
                            ` · ${branchName.get(role.branch_id) ?? "Filial"}`}
                        </small>
                      ))}
                    </td>
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
                      {row.branch_ids
                        .map((id) => branchName.get(id) ?? "Filial")
                        .join(", ") || "Nenhuma"}
                    </td>
                    <td className={styles.actions}>
                      {canManage && <EditUser user={row} />}
                      {canManage && <UserBranches user={row} branches={branchList} />}
                      {canAssign && (
                        <UserRoles
                          user={row}
                          roles={roleList}
                          branches={branchList}
                          branchName={Object.fromEntries(branchName)}
                        />
                      )}
                      {canReset && row.is_active && <TemporaryPassword user={row} />}
                      {canReset && row.is_active && <PdvPin user={row} />}
                      {canReset && row.is_active && <PdvAuthMode user={row} />}
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
