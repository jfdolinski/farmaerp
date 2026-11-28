import 'package:farmaerp_pdv/fiscal/nfce.dart';
import 'package:flutter_test/flutter_test.dart';

// Regras do motor para a NF-e em contingência SVC (sem assinar: as recusas vêm antes).
void main() {
  test('SVC por UF: SVC-RS (7) para AM, BA, CE, GO, MA, MS, MT, PA, PE, PI e PR; SVC-AN (6) para as demais', () {
    for (final uf in ['AM', 'BA', 'CE', 'GO', 'MA', 'MS', 'MT', 'PA', 'PE', 'PI', 'PR']) {
      expect(svcEmissionType(uf), 7, reason: uf);
    }
    for (final uf in ['AC', 'AL', 'AP', 'DF', 'ES', 'MG', 'PB', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO']) {
      expect(svcEmissionType(uf), 6, reason: uf);
    }
    expect(svcEmissionType('XX'), isNull);
  });
}
