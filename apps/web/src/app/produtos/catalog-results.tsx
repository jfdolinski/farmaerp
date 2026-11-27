import Link from "next/link";
import styles from "../terminais/page.module.css";
import { CatalogThumb } from "./images";

export interface CatalogRow {
  id: string;
  name: string;
  active_ingredient: string | null;
  manufacturer: string | null;
  ms_registration: string | null;
  controlled_class: string | null;
  ncm: string | null;
  cest: string | null;
  barcodes: string[];
  product_id: string | null;
  main_image_id?: string | null;
  /** Cadastro provisório no Catálogo: aparece, mas não pode ser vinculado até ficar pronto lá. */
  pending?: boolean;
}

export const controlledLabel = (value: string) =>
  value === "antimicrobial" ? "Antimicrobiano" : `Controlado ${value}`;

/** Resultado da consulta ao Catálogo. A ação de cada item muda conforme a tela. */
export function CatalogResults({
  items,
  actionLabel,
  hrefFor,
}: {
  items: CatalogRow[];
  actionLabel: string;
  hrefFor: (item: CatalogRow) => string;
}) {
  return (
    <div className={styles.tableWrap}>
      <table>
        <thead>
          <tr>
            <th>Imagem</th>
            <th>Item do Catálogo</th>
            <th>Fabricante</th>
            <th>Código de barras</th>
            <th>Ação</th>
          </tr>
        </thead>
        <tbody>
          {items.map((item) => (
            <tr key={item.id}>
              <td>
                <CatalogThumb id={item.main_image_id ?? null} alt={item.name} />
              </td>
              <td>
                {item.name}
                {item.active_ingredient && <small>{item.active_ingredient}</small>}
                {item.pending && (
                  <small className={styles.warning}>Pendente no Catálogo: o cadastro ainda está sendo completado lá.</small>
                )}
                {item.controlled_class && (
                  <small className={styles.warning}>{controlledLabel(item.controlled_class)}</small>
                )}
              </td>
              <td>{item.manufacturer ?? "Não informado"}</td>
              <td>{item.barcodes.join(", ")}</td>
              <td>
                {item.product_id ? (
                  <Link href={`/produtos/${item.product_id}`}>Já cadastrado: abrir</Link>
                ) : item.pending ? (
                  <small className={styles.hint}>Aguardando o Catálogo</small>
                ) : (
                  <Link href={hrefFor(item)}>{actionLabel}</Link>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
