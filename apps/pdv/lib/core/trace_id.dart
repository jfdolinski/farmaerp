import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Gera o ID de rastreio de uma operação. Funciona offline e é ordenado por tempo.
String newTraceId() => _uuid.v7();
