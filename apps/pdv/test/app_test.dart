import 'package:farmaerp_pdv/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('abre a tela inicial do PDV', (tester) async {
    await tester.pumpWidget(const FarmaErpPdvApp());

    expect(find.text('FarmaERP PDV'), findsOneWidget);
  });
}
