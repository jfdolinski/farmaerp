import Link from "next/link";
import styles from "../terminais/page.module.css";
import { count, fileSize, type ImportRow, moment, STATUS_LABELS } from "./labels";

/** Arquivos enviados, com o resultado de cada um. `base` é onde fica o relatório. */
export function ImportList({ rows, base }: { rows: ImportRow[]; base: string }) {
  return (
    <div className={styles.tableWrap}>
      <table>
        <thead>
          <tr>
            <th>Arquivo</th>
            <th>Enviado em</th>
            <th>Situação</th>
            <th>Importadas</th>
            <th>Repetidas</th>
            <th>Ignoradas</th>
            <th>Com problema</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id}>
              <td>
                {row.file_name}
                <br />
                <small>{fileSize(row.size_bytes)}</small>
              </td>
              <td>{moment(row.created_at)}</td>
              <td>{STATUS_LABELS[row.status] ?? row.status}</td>
              <td>{count(row.totals?.imported)}</td>
              <td>{count(row.totals?.duplicate)}</td>
              <td>{count(row.totals?.ignored)}</td>
              <td>{count(row.totals?.failed)}</td>
              <td>
                <Link href={`${base}/${row.id}`}>Ver relatório</Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
