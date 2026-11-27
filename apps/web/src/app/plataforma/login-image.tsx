"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState, useTransition } from "react";
import type { ApiError } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import look from "./login-image.module.css";
import { clearLoginImage } from "./actions";

const MAX_WIDTH = 2560;
const MAX_HEIGHT = 1600;
const MAX_BYTES = 3 * 1024 * 1024;

/** Reduz no navegador para no máximo 2560 × 1600 e envia em JPEG: a tela não precisa de mais que isso. */
async function prepare(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, MAX_WIDTH / bitmap.width, MAX_HEIGHT / bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d")?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  for (const quality of [0.86, 0.75, 0.6]) {
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
    if (blob && blob.size <= MAX_BYTES) return blob;
  }
  throw new Error("grande");
}

const localError = (message: string, action: string): ApiError => ({
  code: "FA225",
  message,
  action,
  retryable: false,
  traceId: null,
});

/** Imagem da tela de entrada da retaguarda e do PDV: escolher, ver como fica e usar. */
export function LoginImageForm({ current }: { current: string | null }) {
  const router = useRouter();
  const [preview, setPreview] = useState<{ url: string; blob: Blob } | null>(null);
  const [error, setError] = useState<ApiError | undefined>();
  const [done, setDone] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  useEffect(() => () => (preview ? URL.revokeObjectURL(preview.url) : undefined), [preview]);

  const shown = preview?.url ?? (current ? `/login/imagem?v=${current}` : null);

  async function choose(file: File | undefined) {
    setError(undefined);
    setDone(null);
    if (!file) return;
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
      setError(localError("Este arquivo não é uma imagem aceita.", "Escolha uma imagem JPEG, PNG ou WebP."));
      return;
    }
    try {
      const blob = await prepare(file);
      setPreview({ url: URL.createObjectURL(blob), blob });
    } catch {
      setError(localError("Não foi possível preparar esta imagem.", "Escolha outra imagem, de preferência em JPEG."));
    }
  }

  function save() {
    if (!preview) return;
    startTransition(async () => {
      const response = await fetch("/plataforma/imagem-entrada", {
        method: "PUT",
        headers: { "Content-Type": "image/jpeg" },
        body: preview.blob,
      });
      if (!response.ok) {
        setError((await response.json()) as ApiError);
        return;
      }
      setPreview(null);
      setDone("Imagem em uso. A retaguarda já mostra a nova imagem; os caixas recebem na próxima sincronização.");
      router.refresh();
    });
  }

  function reset() {
    startTransition(async () => {
      const result = await clearLoginImage();
      if (result.error) {
        setError(result.error);
        return;
      }
      setPreview(null);
      setDone("A tela de entrada voltou para a cor padrão.");
    });
  }

  return (
    <div className={look.layout}>
      <figure className={look.mock} aria-label="Como fica a tela de entrada">
        {shown ? (
          // eslint-disable-next-line @next/next/no-img-element -- prévia local ou a imagem em uso
          <img src={shown} alt="" className={look.mockImage} />
        ) : (
          <span className={look.mockBrand} />
        )}
        <span className={look.mockCard} aria-hidden="true">
          <span />
          <span />
          <span />
        </span>
        <figcaption className={look.caption}>
          {preview ? "Prévia, ainda não está em uso" : current ? "Em uso agora" : "Sem imagem: cor da marca"}
        </figcaption>
      </figure>

      <div className={styles.stack}>
        <p className={styles.hint}>
          A mesma imagem aparece na entrada da retaguarda e dos caixas, ocupando a tela toda, com o cartão de entrada à
          direita. Prefira uma foto larga (paisagem), sem texto, com o lado direito mais calmo. Ela é reduzida para no
          máximo 2560 × 1600 antes de enviar.
        </p>
        <p className={styles.hint}>Use só imagens que vocês têm o direito de usar (foto própria ou com licença).</p>
        <label>
          Escolher imagem
          <input
            type="file"
            accept="image/jpeg,image/png,image/webp"
            onChange={(event) => choose(event.target.files?.[0])}
            disabled={pending}
          />
        </label>
        <div className={styles.inline}>
          <button type="submit" onClick={save} disabled={!preview || pending}>
            {pending && preview ? "Enviando..." : "Usar esta imagem"}
          </button>
          {current && (
            <button type="button" onClick={reset} disabled={pending}>
              Voltar para a cor padrão
            </button>
          )}
        </div>
        <ErrorNotice error={error} />
        {done && (
          <p className={styles.success} role="status">
            {done}
          </p>
        )}
      </div>
    </div>
  );
}
