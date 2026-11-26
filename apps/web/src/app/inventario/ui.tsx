"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { applyCount, cancelCount, type CountFormState, createCount, loadFile, removeItem, setItem } from "./actions";

/** Agora no horário de Brasília, no formato do campo de data e hora. */
function nowLocal(): string {
  return new Date()
    .toLocaleString("sv-SE", { timeZone: "America/Sao_Paulo", hour12: false })
    .slice(0, 16)
    .replace(" ", "T");
}

export function NewCountForm({ branches }: { branches: { id: string; name: string }[] }) {
  const [state, action, pending] = useActionState<CountFormState, FormData>(createCount, {});
  return (
    <form action={action} className={styles.stack}>
      <div className={styles.inline}>
        <label>
          Filial
          <select name="branchId" required defaultValue="">
            <option value="" disabled>
              Escolha
            </option>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Data e hora do corte
          <input type="datetime-local" name="cutoffAt" required defaultValue={nowLocal()} />
        </label>
        <label>
          Observação (opcional)
          <input name="note" maxLength={200} size={30} />
        </label>
        <button type="submit" disabled={pending}>
          Abrir inventário
        </button>
      </div>
      <p className={styles.hint}>
        O corte é o momento a que a contagem se refere (por exemplo, o fechamento da loja). O caixa pode continuar
        vendendo: o que acontecer depois do corte não entra na diferença.
      </p>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function FileForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<CountFormState, FormData>(loadFile, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.loaded) form.current?.reset();
  }, [state]);
  return (
    <form ref={form} action={action} className={styles.stack}>
      <input type="hidden" name="id" value={id} />
      <div className={styles.inline}>
        <label>
          Planilha (.csv)
          <input type="file" name="file" accept=".csv,text/csv,text/plain" required />
        </label>
        <button type="submit" disabled={pending}>
          {pending ? "Enviando..." : "Enviar planilha"}
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.loaded && (
        <div>
          <p className={styles.success}>
            {state.loaded.accepted.toLocaleString("pt-BR")} linha(s) somadas à contagem.
            {state.loaded.rejected_total > 0 && ` ${state.loaded.rejected_total.toLocaleString("pt-BR")} recusada(s):`}
          </p>
          {state.loaded.rejected.length > 0 && (
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Linha</th>
                    <th>Código</th>
                    <th>Motivo</th>
                  </tr>
                </thead>
                <tbody>
                  {state.loaded.rejected.map((row) => (
                    <tr key={row.line}>
                      <td>{row.line}</td>
                      <td>{row.lookup || "—"}</td>
                      <td>{row.reason}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </form>
  );
}

export function ItemForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<CountFormState, FormData>(setItem, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);
  return (
    <form ref={form} action={action} className={styles.stack}>
      <input type="hidden" name="id" value={id} />
      <div className={styles.inline}>
        <label>
          Código (barras, interno ou anterior)
          <input name="lookup" required maxLength={60} size={18} />
        </label>
        <label>
          Quantidade
          <input name="quantity" required inputMode="decimal" size={8} />
        </label>
        <label>
          Lote (se exigir)
          <input name="batch" maxLength={30} size={10} />
        </label>
        <label>
          Validade (se exigir)
          <input type="date" name="expiresOn" />
        </label>
        <button type="submit" disabled={pending}>
          Gravar
        </button>
      </div>
      <p className={styles.hint}>A digitação define a quantidade da linha (a planilha soma).</p>
      <ErrorNotice error={state.error} />
      {state.done && <p className={styles.success}>Contagem gravada.</p>}
    </form>
  );
}

export function RemoveItemButton({ id, itemId }: { id: string; itemId: string }) {
  const [state, action, pending] = useActionState<CountFormState, FormData>(removeItem, {});
  return (
    <form action={action}>
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="itemId" value={itemId} />
      <button type="submit" disabled={pending}>
        Tirar
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function ApplyForm({ id, zeroed, blocked }: { id: string; zeroed: number; blocked: boolean }) {
  const [state, action, pending] = useActionState<CountFormState, FormData>(applyCount, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="id" value={id} />
      <label className={styles.check}>
        <input type="checkbox" name="confirm" required />
        Conferi as diferenças e entendo que {zeroed.toLocaleString("pt-BR")} produto(s) ou lote(s) não contado(s) vão a
        zero. Depois de aplicado, o inventário não muda.
      </label>
      <div className={styles.inline}>
        <button type="submit" disabled={pending || blocked}>
          {pending ? "Aplicando..." : "Aplicar o inventário"}
        </button>
      </div>
      {blocked && <p className={styles.warning}>Corrija as linhas com problema antes de aplicar.</p>}
      <ErrorNotice error={state.error} />
      {state.applied && (
        <p className={styles.success}>
          Inventário aplicado: {state.applied.raised} acrescentado(s), {state.applied.lowered} baixado(s) e{" "}
          {state.applied.zeroed} zerado(s).
        </p>
      )}
    </form>
  );
}

export function CancelForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<CountFormState, FormData>(cancelCount, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="id" value={id} />
      <label className={styles.check}>
        <input type="checkbox" name="confirm" required />
        Desistir deste inventário (o estoque não muda e a contagem fica guardada só para consulta).
      </label>
      <div className={styles.inline}>
        <button type="submit" disabled={pending}>
          Cancelar o inventário
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}
