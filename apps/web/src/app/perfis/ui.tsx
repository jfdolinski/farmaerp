"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import { createRole, deleteRole, RoleFormState, updateRole } from "./actions";
import styles from "../terminais/page.module.css";

export interface PermissionRow {
  code: string;
  module: string;
  name: string;
}

export interface RoleRow {
  id: string;
  name: string;
  description: string | null;
  system_key: string | null;
  permissions: string[];
}

function modulesOf(permissions: PermissionRow[]) {
  const modules = new Map<string, PermissionRow[]>();
  for (const permission of permissions) {
    modules.set(permission.module, [
      ...(modules.get(permission.module) ?? []),
      permission,
    ]);
  }
  return [...modules.entries()];
}

function PermissionGrid({
  permissions,
  checked,
  own,
  disabled,
}: {
  permissions: PermissionRow[];
  checked: (code: string) => boolean;
  own: string[];
  disabled?: boolean;
}) {
  return (
    <div className={styles.grid}>
      {modulesOf(permissions).map(([module, items]) => (
        <fieldset key={module} className={styles.group}>
          <legend>{module}</legend>
          {items.map((permission) => {
            const isChecked = checked(permission.code);
            // Permissão que a pessoa não tem: pode tirar, mas não pode dar.
            const locked = disabled || (!own.includes(permission.code) && !isChecked);
            return (
              <label key={permission.code} className={styles.check}>
                <input
                  type="checkbox"
                  name="permissions"
                  value={permission.code}
                  defaultChecked={isChecked}
                  disabled={locked}
                />
                {permission.name}
              </label>
            );
          })}
        </fieldset>
      ))}
    </div>
  );
}

export function CreateRoleForm({
  permissions,
  own,
}: {
  permissions: PermissionRow[];
  own: string[];
}) {
  const [state, action, pending] = useActionState<RoleFormState, FormData>(
    createRole,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  return (
    <section className={styles.card}>
      <h2>Novo perfil</h2>
      <form ref={form} action={action} className={styles.stack}>
        <div className={styles.inline}>
          <label>
            Nome
            <input name="name" required maxLength={100} />
          </label>
          <label>
            Descrição
            <input name="description" maxLength={500} />
          </label>
        </div>
        <PermissionGrid permissions={permissions} checked={() => false} own={own} />
        <div>
          <button type="submit" disabled={pending}>
            Criar perfil
          </button>
        </div>
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Perfil criado.
          </p>
        )}
      </form>
    </section>
  );
}

export function RoleCard({
  role,
  permissions,
  own,
  canManage,
}: {
  role: RoleRow;
  permissions: PermissionRow[];
  own: string[];
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<RoleFormState, FormData>(
    updateRole,
    {},
  );
  const [removal, removeAction, removing] = useActionState<RoleFormState, FormData>(
    deleteRole,
    {},
  );
  const isSystem = role.system_key !== null;
  const editable = canManage && !isSystem;

  return (
    <section className={styles.card}>
      <h2>{role.name}</h2>
      {isSystem && (
        <p className={styles.hint}>
          Acesso total, inclusive às permissões de novos módulos. Este perfil não pode ser alterado.
        </p>
      )}
      <form action={action} className={styles.stack}>
        <input type="hidden" name="id" value={role.id} />
        {editable ? (
          <div className={styles.inline}>
            <label>
              Nome
              <input name="name" required maxLength={100} defaultValue={role.name} />
            </label>
            <label>
              Descrição
              <input name="description" maxLength={500} defaultValue={role.description ?? ""} />
            </label>
          </div>
        ) : (
          !isSystem && role.description && <p className={styles.hint}>{role.description}</p>
        )}
        <PermissionGrid
          permissions={permissions}
          checked={(code) => isSystem || role.permissions.includes(code)}
          own={own}
          disabled={!editable}
        />
        {editable && (
          <div>
            <button type="submit" disabled={pending}>
              Salvar perfil
            </button>
          </div>
        )}
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Perfil salvo.
          </p>
        )}
      </form>
      {editable && (
        <form action={removeAction} className={styles.stack}>
          <input type="hidden" name="id" value={role.id} />
          <div>
            <button type="submit" disabled={removing} className={styles.danger}>
              Excluir perfil
            </button>
          </div>
          <ErrorNotice error={removal.error} />
        </form>
      )}
    </section>
  );
}
