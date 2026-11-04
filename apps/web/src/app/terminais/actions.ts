"use server";

import { refresh } from "next/cache";
import { cookies } from "next/headers";
import { apiFetch, ApiError } from "@/lib/api";
import { DEV_USER_COOKIE, DEV_USERS } from "@/lib/dev-users";

export interface ActionState {
  error?: ApiError;
  done?: boolean;
}

export interface PairingDevice {
  platform: string;
  deviceName: string;
  appVersion: string;
  keyStorage: string;
  expiresAt: string;
}

export interface LookupState extends ActionState {
  code?: string;
  device?: PairingDevice;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();

async function post(path: string, body: unknown): Promise<ActionState> {
  const result = await apiFetch(path, { method: "POST", body });
  if (!result.ok) {
    return { error: result.error };
  }
  refresh();
  return { done: true };
}

export async function lookupPairing(
  _previous: LookupState,
  form: FormData,
): Promise<LookupState> {
  const code = text(form, "code");
  const result = await apiFetch<PairingDevice>(
    `/admin/pairing/${encodeURIComponent(code)}`,
  );
  return result.ok
    ? { code, device: result.data }
    : { code, error: result.error };
}

export async function claimPairing(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  return post(`/admin/pairing/${encodeURIComponent(text(form, "code"))}/claim`, {
    branchId: text(form, "branchId"),
  });
}

export async function approveTerminal(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  return post(`/admin/terminals/${text(form, "id")}/approve`, {
    name: text(form, "name"),
    profile: text(form, "profile"),
  });
}

export async function changeTerminalStatus(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  const action = text(form, "action");
  if (!["block", "unblock", "revoke"].includes(action)) {
    return {};
  }
  return post(`/admin/terminals/${text(form, "id")}/${action}`, {
    reason: text(form, "reason"),
  });
}

export async function selectDevUser(form: FormData): Promise<void> {
  const id = text(form, "userId");
  if (DEV_USERS.some((user) => user.id === id)) {
    (await cookies()).set(DEV_USER_COOKIE, id, { httpOnly: true, sameSite: "lax" });
    refresh();
  }
}

export async function refreshPanel(): Promise<void> {
  refresh();
}
