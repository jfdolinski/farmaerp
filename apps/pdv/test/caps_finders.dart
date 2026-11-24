import 'package:farmaerp_pdv/ui/caps.dart';
import 'package:flutter_test/flutter_test.dart';

/// O PDV mostra tudo em caixa alta: os testes procuram o texto já convertido.
Finder findText(String text) => find.text(caps(text));

Finder findTextContaining(String text) => find.textContaining(caps(text));
