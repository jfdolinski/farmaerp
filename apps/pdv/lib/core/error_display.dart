import 'error_catalog.g.dart';

const _fallbackCode = 'FA000';
const _referenceLength = 8;

/// Erro pronto para mostrar ao operador. O detalhe técnico fica só no log.
class ErrorDisplay {
  const ErrorDisplay({
    required this.message,
    required this.action,
    required this.reference,
    required this.retryable,
  });

  /// Monta a exibição; um código desconhecido vira o erro genérico.
  factory ErrorDisplay.fromCode(String code, {String? traceId}) {
    final entry = errorCatalog[code] ?? errorCatalog[_fallbackCode]!;
    return ErrorDisplay(
      message: entry.message,
      action: entry.action,
      reference: formatReference(entry.code, traceId),
      retryable: entry.retryable,
    );
  }

  final String message;
  final String action;
  final String reference;
  final bool retryable;
}

/// Exemplo: `Código FA203 · Ref. a1b2c3d4`, para o operador informar ao suporte.
String formatReference(String code, String? traceId) {
  if (traceId == null || traceId.length < _referenceLength) {
    return 'Código $code';
  }
  final suffix = traceId.substring(traceId.length - _referenceLength);
  return 'Código $code · Ref. $suffix';
}
