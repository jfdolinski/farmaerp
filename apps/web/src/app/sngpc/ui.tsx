"use client";

import { useActionState, useState, useTransition } from "react";
import type { ApiError } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import {
  checkMovements,
  completeSale,
  confirmMovements,
  disregardMovement,
  openSngpc,
  SngpcState,
  updateMovement,
} from "./actions";
import {
  dayText,
  KIND,
  LOSS_REASON,
  PRESCRIPTION_TYPE,
  prescriptionText,
  problemText,
  quantityText,
  SngpcBatch,
  SngpcMovement,
  SngpcProblem,
} from "./format";
import styles from "../terminais/page.module.css";

function Saved({ state }: { state: SngpcState }) {
  return (
    <>
      {state.done && <p className={styles.success}>Salvo.</p>}
      <ErrorNotice error={state.error} />
    </>
  );
}

export function OpenSngpcForm({ branchId }: { branchId: string }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(openSngpc, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="branchId" value={branchId} />
      <p>
        Ao abrir, o saldo de cada lote de controlado da filial vira o inventário inicial, para você conferir com a
        contagem. Daí em diante, toda entrada, venda, perda e transferência de controlado fica pendente aqui.
      </p>
      <div className={styles.inline}>
        <button type="submit" disabled={pending}>
          Abrir o SNGPC desta filial
        </button>
      </div>
      <Saved state={state} />
    </form>
  );
}

function DateForm({ row, today }: { row: SngpcMovement; today: string }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(updateMovement, {});
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="movementId" value={row.id} />
      <label>
        Data no SNGPC
        <input type="date" name="reportedOn" defaultValue={row.reported_on} max={today} required />
      </label>
      <button type="submit" disabled={pending}>
        Salvar data
      </button>
      <Saved state={state} />
    </form>
  );
}

function LossReasonForm({ row }: { row: SngpcMovement }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(updateMovement, {});
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="movementId" value={row.id} />
      <label>
        Motivo da perda
        <select name="lossReason" defaultValue={row.loss_reason ?? ""} required>
          <option value="" disabled>
            Escolha
          </option>
          {Object.entries(LOSS_REASON).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>
      <button type="submit" disabled={pending}>
        Salvar motivo
      </button>
      <Saved state={state} />
    </form>
  );
}

function BatchSelect({ batches, initial }: { batches: SngpcBatch[]; initial?: string | null }) {
  return (
    <select name="batchId" defaultValue={initial ?? ""} required>
      <option value="" disabled>
        Escolha o lote
      </option>
      {batches.map((batch) => (
        <option key={batch.id} value={batch.id}>
          {batch.batch_number} · vence {dayText(batch.expires_on)} · saldo {quantityText(batch.quantity)}
          {batch.ms_registration ? "" : " · sem MS"}
        </option>
      ))}
    </select>
  );
}

function BatchForm({ row, batches }: { row: SngpcMovement; batches: SngpcBatch[] }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(updateMovement, {});
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="movementId" value={row.id} />
      <label>
        Lote
        <BatchSelect batches={batches} initial={row.batch_id} />
      </label>
      <button type="submit" disabled={pending}>
        Salvar lote
      </button>
      <Saved state={state} />
    </form>
  );
}

function QuantityForm({ row }: { row: SngpcMovement }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(updateMovement, {});
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="movementId" value={row.id} />
      <label>
        Quantidade contada
        <input name="quantity" inputMode="decimal" defaultValue={quantityText(row.quantity)} required size={8} />
      </label>
      <button type="submit" disabled={pending}>
        Salvar quantidade
      </button>
      <Saved state={state} />
    </form>
  );
}

function DisregardForm({ row }: { row: SngpcMovement }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(disregardMovement, {});
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="movementId" value={row.id} />
      <label>
        Motivo para deixar fora do SNGPC
        <input name="reason" maxLength={500} required size={36} />
      </label>
      <button type="submit" disabled={pending}>
        Deixar fora
      </button>
      <Saved state={state} />
    </form>
  );
}

function CompleteSaleForm({ row, batches }: { row: SngpcMovement; batches: SngpcBatch[] }) {
  const [state, action, pending] = useActionState<SngpcState, FormData>(completeSale, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="movementId" value={row.id} />
      <p className={styles.hint}>
        Venda liberada no caixa sem a receita. A receita precisa ser da data da venda ou de antes, dentro da validade.
      </p>
      <div className={styles.inline}>
        <label>
          Lote
          <BatchSelect batches={batches} initial={row.batch_id} />
        </label>
        <label>
          Tipo de receita
          <select name="prescriptionType" required defaultValue="">
            <option value="" disabled>
              Escolha
            </option>
            {Object.entries(PRESCRIPTION_TYPE).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Número
          <input name="prescriptionNumber" maxLength={30} size={12} />
        </label>
        <label>
          Data da receita
          <input type="date" name="prescriptionDate" required />
        </label>
      </div>
      <div className={styles.inline}>
        <label>
          Prescritor
          <input name="prescriberName" required maxLength={150} size={24} />
        </label>
        <label>
          Conselho
          <select name="prescriberCouncil" required defaultValue="CRM">
            {["CRM", "CRO", "CRMV", "COREN", "CRF", "RMS"].map((value) => (
              <option key={value}>{value}</option>
            ))}
          </select>
        </label>
        <label>
          Número
          <input name="prescriberNumber" required maxLength={20} size={10} />
        </label>
        <label>
          UF
          <input name="prescriberState" required maxLength={2} size={3} />
        </label>
      </div>
      <div className={styles.inline}>
        <label>
          Comprador
          <input name="buyerName" required maxLength={150} size={24} />
        </label>
        <label>
          Documento
          <select name="buyerDocumentType" required defaultValue="rg">
            <option value="rg">RG</option>
            <option value="cpf">CPF</option>
            <option value="cnh">CNH</option>
            <option value="passport">Passaporte</option>
            <option value="other">Outro</option>
          </select>
        </label>
        <label>
          Número
          <input name="buyerDocument" required maxLength={30} size={14} />
        </label>
        <label>
          Órgão emissor
          <input name="buyerIssuer" required maxLength={20} size={8} />
        </label>
        <label>
          UF
          <input name="buyerState" required maxLength={2} size={3} />
        </label>
      </div>
      <div className={styles.inline}>
        <label>
          Paciente (opcional)
          <input name="patientName" maxLength={150} size={24} />
        </label>
        <label>
          Idade
          <input name="patientAge" inputMode="numeric" maxLength={3} size={4} />
        </label>
        <label>
          Sexo
          <select name="patientSex" defaultValue="">
            <option value="">—</option>
            <option value="F">Feminino</option>
            <option value="M">Masculino</option>
          </select>
        </label>
        <button type="submit" disabled={pending}>
          Salvar receita
        </button>
      </div>
      <Saved state={state} />
    </form>
  );
}

function RowActions({ row, batches, today }: { row: SngpcMovement; batches: SngpcBatch[]; today: string }) {
  const saleWithoutPrescription = row.kind === "sale" && (row.dispensing_status === "pending" || row.dispensing_status === "complemented");
  return (
    <details className={styles.reason}>
      <summary>Corrigir</summary>
      {row.kind === "inventory" && <QuantityForm row={row} />}
      {row.kind !== "inventory" && <DateForm row={row} today={today} />}
      {(row.kind === "loss" || row.kind === "adjustment_out") && <LossReasonForm row={row} />}
      {!row.origin_batch && row.kind !== "sale" && row.kind !== "inventory" && <BatchForm row={row} batches={batches} />}
      {saleWithoutPrescription && <CompleteSaleForm row={row} batches={batches} />}
      {["inventory", "adjustment_in", "adjustment_out"].includes(row.kind) && <DisregardForm row={row} />}
    </details>
  );
}

/** Pendências na ordem do SNGPC: escolher, simular e conferir com a senha. */
export function PendingBoard({
  branchId,
  rows,
  batches,
  today,
}: {
  branchId: string;
  rows: SngpcMovement[];
  batches: Record<string, SngpcBatch[]>;
  today: string;
}) {
  const [selected, setSelected] = useState<string[]>([]);
  const [problems, setProblems] = useState<SngpcProblem[] | null>(null);
  const [error, setError] = useState<ApiError | undefined>();
  const [message, setMessage] = useState<string | null>(null);
  const [sendOn, setSendOn] = useState(today);
  const [password, setPassword] = useState("");
  const [busy, start] = useTransition();
  const toggle = (id: string) => {
    setProblems(null);
    setSelected((current) => (current.includes(id) ? current.filter((x) => x !== id) : [...current, id]));
  };
  const simulate = () =>
    start(async () => {
      setMessage(null);
      const result = await checkMovements(branchId, selected);
      setError(result.error);
      setProblems(result.problems ?? null);
    });
  const confirm = () =>
    start(async () => {
      setMessage(null);
      const result = await confirmMovements(branchId, selected, sendOn, password);
      setError(result.error);
      setPassword("");
      if (result.confirmed !== undefined) {
        setMessage(`${result.confirmed} movimentação(ões) conferida(s), com envio em ${dayText(sendOn)}.`);
        setSelected([]);
        setProblems(null);
      }
    });
  const problemsOf = (id: string) => (problems ?? []).filter((p) => p.movement_id === id);

  // Sem pendências, o quadro continua montado para a mensagem da última conferência ficar na tela.
  if (rows.length === 0) {
    return (
      <div className={styles.stack}>
        <p className={styles.hint}>Nenhuma pendência.</p>
        {message && <p className={styles.success}>{message}</p>}
      </div>
    );
  }

  return (
    <div className={styles.stack}>
      <div className={styles.tableWrap}>
        <table>
          <thead>
            <tr>
              <th>
                <input
                  type="checkbox"
                  aria-label="Marcar todas"
                  checked={rows.length > 0 && selected.length === rows.length}
                  onChange={(event) => {
                    setProblems(null);
                    setSelected(event.target.checked ? rows.map((r) => r.id) : []);
                  }}
                />
              </th>
              <th>Data</th>
              <th>Movimentação</th>
              <th>Produto</th>
              <th>Lote e MS</th>
              <th>Quantidade</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const found = problemsOf(row.id);
              return (
                <tr key={row.id} data-movement={row.id}>
                  <td>
                    <input
                      type="checkbox"
                      aria-label={`Escolher ${KIND[row.kind] ?? row.kind} de ${row.product_name}`}
                      checked={selected.includes(row.id)}
                      onChange={() => toggle(row.id)}
                    />
                  </td>
                  <td>{dayText(row.reported_on)}</td>
                  <td>
                    {KIND[row.kind] ?? row.kind}
                    {row.counterpart && <small>{row.counterpart}</small>}
                    {row.loss_reason && <small>{LOSS_REASON[row.loss_reason]}</small>}
                    {row.prescription && <small>{prescriptionText(row.prescription)}</small>}
                    {row.buyer && <small>{row.buyer}</small>}
                    {row.dispensing_status === "pending" && <small className={styles.warning}>Liberada sem receita</small>}
                  </td>
                  <td>
                    {row.product_name}
                    <small>
                      Código {row.product_code}
                      {row.controlled_class ? ` · lista ${row.controlled_class === "antimicrobial" ? "antimicrobiano" : row.controlled_class}` : ""}
                    </small>
                  </td>
                  <td>
                    {row.batch_number ?? "Sem lote"}
                    <small>{row.ms_registration ? `MS ${row.ms_registration}` : "Sem MS"}</small>
                  </td>
                  <td>{quantityText(row.quantity)}</td>
                  <td>
                    <RowActions row={row} batches={batches[row.product_id] ?? []} today={today} />
                    {problems !== null && selected.includes(row.id) && found.length === 0 && (
                      <small className={styles.success}>Pronta para conferir</small>
                    )}
                    {found.map((p) => (
                      <small key={p.problem} className={styles.warning}>
                        {problemText(p)}
                      </small>
                    ))}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className={styles.inline}>
        <button type="button" onClick={simulate} disabled={busy || selected.length === 0}>
          Simular ({selected.length})
        </button>
      </div>
      <fieldset className={styles.fieldset}>
        <legend>Conferência</legend>
        <div className={styles.inline}>
          <label>
            Data de envio
            <input type="date" value={sendOn} min={today} onChange={(event) => setSendOn(event.target.value)} required />
          </label>
          <label>
            Sua senha
            <input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} />
          </label>
          <button type="button" onClick={confirm} disabled={busy || selected.length === 0 || password === ""}>
            Conferir {selected.length} movimentação(ões)
          </button>
        </div>
        <p className={styles.hint}>
          Conferir é a sua assinatura: as movimentações escolhidas não mudam mais e entram no envio da data marcada.
        </p>
      </fieldset>
      {message && <p className={styles.success}>{message}</p>}
      <ErrorNotice error={error} />
    </div>
  );
}
