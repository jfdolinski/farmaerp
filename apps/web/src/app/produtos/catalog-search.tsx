"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import styles from "../terminais/page.module.css";
import search from "./catalog-search.module.css";

/** GTIN com 8, 12, 13 ou 14 dígitos: tamanho de código de barras de produto. */
const looksLikeBarcode = (value: string) => /^(\d{8}|\d{12,14})$/.test(value);

/**
 * Código de barras com busca automática no Catálogo: ao completar um código (digitado ou lido pelo
 * leitor), a tela consulta sozinha, sem precisar clicar.
 */
export function BarcodeLookupField({ base, initial }: { base: string; initial: string }) {
  const router = useRouter();
  const [value, setValue] = useState(initial);
  const [searching, setSearching] = useState(false);
  const last = useRef(initial);

  useEffect(() => {
    const code = value.trim();
    if (!looksLikeBarcode(code) || code === last.current) return;
    const timer = window.setTimeout(() => {
      last.current = code;
      setSearching(true);
      router.replace(`${base}?ean=${code}`, { scroll: false });
    }, 350);
    return () => window.clearTimeout(timer);
  }, [value, base, router]);

  return (
    <form
      action={base}
      className={styles.inline}
      onSubmit={() => {
        last.current = value.trim();
        setSearching(true);
      }}
    >
      <label>
        Código de barras
        <input
          name="ean"
          inputMode="numeric"
          autoComplete="off"
          maxLength={14}
          size={18}
          value={value}
          onChange={(event) => {
            setSearching(false);
            setValue(event.target.value.replace(/\D/g, ""));
          }}
          autoFocus
          required
        />
      </label>
      <button type="submit">Procurar</button>
      {searching && (
        <span className={search.searching} role="status">
          Procurando no Catálogo...
        </span>
      )}
    </form>
  );
}

/** Botão que abre a busca manual no Catálogo por cima da tela. */
export function CatalogSearchButton({
  action,
  initial = "",
  keep = {},
  label = "Buscar no Catálogo",
  name = "catalogo",
}: {
  action: string;
  initial?: string;
  keep?: Record<string, string>;
  label?: string;
  /** Nome do parâmetro do endereço com o texto buscado. */
  name?: string;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  return (
    <>
      <button type="button" className={search.openButton} onClick={() => dialog.current?.showModal()}>
        {label}
      </button>
      <dialog
        ref={dialog}
        className={search.dialog}
        aria-labelledby="busca-catalogo-titulo"
        onClick={(event) => {
          // Clique fora da caixa fecha.
          if (event.target === dialog.current) dialog.current?.close();
        }}
      >
        <form action={action} className={search.dialogBody}>
          <h2 id="busca-catalogo-titulo">Buscar no Catálogo</h2>
          {Object.entries(keep).map(([field, value]) => (
            <input key={field} type="hidden" name={field} value={value} />
          ))}
          <label>
            Nome, código de barras, princípio ativo ou fabricante
            <input name={name} type="search" maxLength={200} defaultValue={initial} required autoFocus />
          </label>
          <div className={search.dialogActions}>
            <button type="button" onClick={() => dialog.current?.close()}>
              Fechar
            </button>
            <button type="submit">Buscar</button>
          </div>
        </form>
      </dialog>
    </>
  );
}
