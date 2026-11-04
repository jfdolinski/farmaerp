/** Erro da aplicação com código do catálogo. A causa técnica fica só no log. */
export class AppError extends Error {
  constructor(
    readonly code: string,
    options?: { cause?: unknown },
  ) {
    super(code, options);
    this.name = 'AppError';
  }
}
