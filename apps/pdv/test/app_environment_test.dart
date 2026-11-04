import 'package:farmaerp_pdv/core/app_environment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isApiUrlAllowed', () {
    test('desenvolvimento aceita HTTP local', () {
      expect(isApiUrlAllowed('development', 'http://localhost:3001'), isTrue);
    });

    test('homologação e produção exigem HTTPS', () {
      for (final environment in ['homologation', 'production']) {
        expect(
          isApiUrlAllowed(environment, 'https://hom-api.exemplo.com.br'),
          isTrue,
        );
        expect(
          isApiUrlAllowed(environment, 'http://hom-api.exemplo.com.br'),
          isFalse,
        );
        expect(isApiUrlAllowed(environment, 'http://localhost:3001'), isFalse);
      }
    });

    test('ambiente desconhecido também exige HTTPS', () {
      expect(isApiUrlAllowed('outro', 'http://api.exemplo.com.br'), isFalse);
    });

    test('recusa endereço inválido em qualquer ambiente', () {
      expect(isApiUrlAllowed('development', ''), isFalse);
      expect(isApiUrlAllowed('production', 'nao-e-endereco'), isFalse);
    });
  });

  group('EnvironmentBanner', () {
    Future<void> pump(WidgetTester tester, String environment) =>
        tester.pumpWidget(
          MaterialApp(
            home: EnvironmentBanner(
              environment: environment,
              child: const Text('conteúdo'),
            ),
          ),
        );

    testWidgets('aparece na homologação', (tester) async {
      await pump(tester, 'homologation');
      expect(find.textContaining('HOMOLOGAÇÃO'), findsOneWidget);
      expect(find.text('conteúdo'), findsOneWidget);
    });

    testWidgets('não aparece nos demais ambientes', (tester) async {
      for (final environment in ['development', 'production']) {
        await pump(tester, environment);
        expect(find.textContaining('HOMOLOGAÇÃO'), findsNothing);
        expect(find.text('conteúdo'), findsOneWidget);
      }
    });
  });
}
