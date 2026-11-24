"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

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

function failure(error: ApiError): { error: ApiError } {
  if (error.code === "FA402") redirect("/login?next=/terminais&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

async function post(path: string, body: unknown): Promise<ActionState> {
  const result = await apiFetch(path, { method: "POST", body });
  if (!result.ok) {
    return failure(result.error);
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
    : { code, ...failure(result.error) };
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

/** Tempo sem internet para a venda sem estoque: da filial (padrão) ou do terminal (exceção). */
export async function setOfflineMinutes(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  const scope = text(form, "scope") === "branch" ? "branches" : "terminals";
  const raw = text(form, "minutes");
  const minutes = raw === "" || text(form, "inherit") === "1" ? null : Number(raw);
  return post(`/admin/${scope}/${text(form, "id")}/offline-minutes`, { minutes });
}

export async function setTerminalProfile(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  return post(`/admin/terminals/${text(form, "id")}/profile`, { profile: text(form, "profile") });
}

export async function setReturnDays(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  const raw = text(form, "days");
  return post(`/admin/branches/${text(form, "id")}/return-days`, { days: raw === "" ? null : Number(raw) });
}

export async function setSaleSettings(
  _previous: ActionState,
  form: FormData,
): Promise<ActionState> {
  const raw = text(form, "days");
  return post(`/admin/branches/${text(form, "id")}/sale-settings`, {
    quoteValidityDays: raw === "" ? null : Number(raw),
    sellerPinRequired: text(form, "pin") === "1",
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
