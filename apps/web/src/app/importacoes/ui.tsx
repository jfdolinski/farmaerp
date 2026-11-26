"use client";

import { getError } from "@farmaerp/error-catalog";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import type { ApiError } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { completeImport, startImport } from "./actions";
import { fileSize } from "./labels";

/** A retaguarda repassa cada parte à API; o proxy do Next aceita até 10 MB por requisição. */
const MAX_PART = 8 * 1024 * 1024;
const MAX_FILE = 1024 * 1024 * 1024;
const ATTEMPTS = 3;

function catalogError(code: string): ApiError {
  const { message, action, retryable } = getError(code);
  return { code, message, action, retryable, traceId: null };
}

/** Envia uma parte; tenta de novo só quando a conexão cai (a API não chegou a responder). */
async function sendPart(id: string, part: number, blob: Blob): Promise<ApiError | null> {
  for (let attempt = 1; attempt <= ATTEMPTS; attempt += 1) {
    let response: Response;
    try {
      response = await fetch(`/importacoes/envio/${id}/${part}`, {
        method: "PUT",
        headers: { "Content-Type": "application/octet-stream" },
        body: blob,
      });
    } catch {
      if (attempt === ATTEMPTS) return catalogError("FA001");
      await new Promise((resolve) => setTimeout(resolve, 2000 * attempt));
      continue;
    }
    if (response.ok) return null;
    try {
      return (await response.json()) as ApiError;
    } catch {
      return catalogError("FA001");
    }
  }
  return catalogError("FA001");
}

/** Escolha do .zip e envio em partes, com o andamento. */
export function ImportUploader() {
  const router = useRouter();
  const [file, setFile] = useState<File | null>(null);
  const [sent, setSent] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<ApiError | undefined>();

  // Fechar a página no meio do envio perde o que falta.
  useEffect(() => {
    if (!busy) return;
    const warn = (event: BeforeUnloadEvent) => event.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [busy]);

  async function upload() {
    if (!file) return;
    setError(undefined);
    if (!/\.zip$/i.test(file.name) || file.size < 1 || file.size > MAX_FILE) {
      setError(catalogError("FA740"));
      return;
    }
    setBusy(true);
    setSent(0);
    try {
      const started = await startImport(file.name, file.size);
      if (!started.ok) {
        if (started.error.code === "FA402") router.push("/login?next=%2Fimportacoes&expired=1");
        setError(started.error);
        return;
      }
      const { id, partBytes } = started.data;
      const size = Math.min(partBytes, MAX_PART);
      let offset = 0;
      for (let part = 1; offset < file.size; part += 1) {
        const failure = await sendPart(id, part, file.slice(offset, offset + size));
        if (failure) {
          setError(failure);
          return;
        }
        offset = Math.min(offset + size, file.size);
        setSent(offset);
      }
      const done = await completeImport(id);
      if (!done.ok) {
        setError(done.error);
        return;
      }
      router.push(`/importacoes/${id}`);
    } finally {
      setBusy(false);
    }
  }

  const percent = file && file.size > 0 ? Math.floor((sent / file.size) * 100) : 0;
  return (
    <div className={styles.stack}>
      <div className={styles.inline}>
        <label>
          Arquivo .zip com os XML (até 1 GB)
          <input
            type="file"
            accept=".zip,application/zip"
            disabled={busy}
            onChange={(event) => {
              setFile(event.target.files?.[0] ?? null);
              setSent(0);
              setError(undefined);
            }}
          />
        </label>
        <button type="button" disabled={!file || busy} onClick={() => void upload()}>
          {busy ? "Enviando..." : "Enviar e importar"}
        </button>
      </div>
      {file && (busy || sent > 0) && (
        <p className={styles.hint}>
          <progress max={100} value={percent} /> {percent}% · {fileSize(sent)} de {fileSize(file.size)}
          {busy && " · Não feche esta página até terminar o envio."}
        </p>
      )}
      <ErrorNotice error={error} />
    </div>
  );
}

/** Enquanto o arquivo está na fila ou sendo processado, atualiza a tela a cada 5 segundos. */
export function AutoRefresh() {
  const router = useRouter();
  useEffect(() => {
    const timer = setInterval(() => router.refresh(), 5000);
    return () => clearInterval(timer);
  }, [router]);
  return null;
}
