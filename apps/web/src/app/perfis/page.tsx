import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { CreateRoleForm, PermissionRow, RoleCard, RoleRow } from "./ui";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Perfis · FarmaERP" };

export default function RolesPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando perfis...</p>}>
        <RolesContent />
      </Suspense>
    </main>
  );
}

async function RolesContent() {
  const user = await requireUser("/perfis");
  const canManage = can(user, "roles.manage");

  if (!canManage && !can(user, "roles.assign")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Perfis</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os perfis.</p>
        </section>
      </>
    );
  }

  const [roles, permissions] = await Promise.all([
    apiFetch<RoleRow[]>("/admin/roles"),
    apiFetch<PermissionRow[]>("/admin/permissions"),
  ]);
  if (!roles.ok) redirectIfNeeded(roles.error, "/perfis");
  const catalog = permissions.ok ? permissions.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Perfis</h1>
      {canManage && <CreateRoleForm permissions={catalog} own={user.permissions} />}
      {!roles.ok && <ErrorNotice error={roles.error} />}
      {roles.ok &&
        roles.data.map((role) => (
          <RoleCard
            key={role.id}
            role={role}
            permissions={catalog}
            own={user.permissions}
            canManage={canManage}
          />
        ))}
    </>
  );
}
