/** Erro da aplicação com código do catálogo. A causa técnica fica só no log. */
export class AppError extends Error {
  /** Detalhe que pode ir para a tela (ex.: o código e o motivo da Sefaz). Nunca dado pessoal. */
  readonly detail: string | undefined;

  constructor(
    readonly code: string,
    options?: { cause?: unknown; detail?: string },
  ) {
    super(code, options);
    this.detail = options?.detail;
    this.name = 'AppError';
  }
}
