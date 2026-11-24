import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/display_settings.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/ui/caps.dart' as caps_ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';
import 'pos_test.dart' show FakePrinter;

const branchId = '019a0000-0000-7000-8000-000000000005';

LocalDatabase withProfile(String profile) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '1', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'terminal_profile': profile,
      }),
    ]),
    now: DateTime(2026, 11, 24, 10),
  );
  return database;
}

void main() {
  group('aparência', () {
    test('uma cor base, três tons: orçamento claro, caixa médio, autoatendimento forte', () {
      final blue = TerminalKind.values.map((kind) => DisplaySettings.toneOf('blue', kind)).toList();
      expect(blue, [Colors.blue[300], Colors.blue[600], Colors.blue[900]]);
      expect(DisplaySettings.toneOf('green', TerminalKind.selfService), Colors.green[900]);
      // Cor desconhecida cai no azul; texto legível sobre cada tom.
      expect(DisplaySettings.toneOf('rosa', TerminalKind.cashier), Colors.blue[600]);
      expect(DisplaySettings.onTone(Colors.blue[900]!), Colors.white);
      expect(DisplaySettings.onTone(Colors.orange[300]!), Colors.black87);
      expect(TerminalKind.of('self_service'), TerminalKind.selfService);
      expect(TerminalKind.of('outro'), TerminalKind.cashier);
    });

    test('cor e negrito ficam guardados no terminal; o tema segue o tipo do terminal', () {
      final database = withProfile('quote');
      final settings = DisplaySettings(database);
      expect([settings.color, settings.bold], ['blue', false]);
      expect(settings.theme().appBarTheme.backgroundColor, Colors.blue[300]);
      expect(settings.theme().textTheme.bodyMedium?.fontWeight, isNot(FontWeight.bold));
      settings.update(color: 'purple', bold: true);
      settings.update(color: 'rosa');
      final again = DisplaySettings(database);
      expect([again.color, again.bold], ['purple', true]);
      expect(again.theme().appBarTheme.backgroundColor, Colors.deepPurple[300]);
      expect(again.theme(TerminalKind.selfService).appBarTheme.backgroundColor, Colors.deepPurple[900]);
      expect(again.theme().textTheme.bodyMedium?.fontWeight, FontWeight.bold);
      expect(again.theme().textTheme.titleLarge?.fontWeight, FontWeight.bold);
      again.update(bold: false);
      expect(DisplaySettings(database).bold, isFalse);
      database.close();
    });

    for (final (profile, title) in [('quote', 'Orçamento 4'), ('cashier', 'Caixa 4'), ('self_service', 'Autoatendimento 4')]) {
      testWidgets('tela do terminal $profile: nome, ícone, faixa e tom próprios', (tester) async {
        final database = withProfile(profile);
        database.setSetting(DisplaySettings.colorKey, 'green');
        final kind = TerminalKind.of(profile);
        final controller = PosController(
          database: database,
          auth: PosAuth(database: database),
          printer: FakePrinter.new,
          terminalNumber: () => 4,
        );
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
        expect(tester.widget<Text>(find.byKey(const Key('terminal-title'))).data, caps_ui.caps(title));
        expect(find.descendant(of: find.byKey(const Key('terminal-kind')), matching: find.byIcon(kind.icon)), findsOneWidget);
        expect(find.byKey(Key('terminal-band-$profile')), findsOneWidget);
        expect(find.descendant(of: find.byKey(Key('terminal-band-$profile')), matching: findText(kind.label)), findsOneWidget);
        final bar = tester.widget<Material>(find.descendant(of: find.byType(AppBar), matching: find.byType(Material)).first);
        expect(bar.color, Colors.green[kind.shade]);
        expect(findTextContaining('· ${kind.label} 4'), findsOneWidget);
        await tester.binding.setSurfaceSize(null);
        database.close();
      });
    }
  });

  group('caixa alta', () {
    testWidgets('textos, rótulos e o que se digita aparecem em caixa alta; senha não muda', (tester) async {
      final typed = TextEditingController();
      final secret = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const caps_ui.Text('Venda concluída', key: Key('label')),
              caps_ui.TextField(
                key: const Key('typed'),
                controller: typed,
                decoration: const caps_ui.InputDecoration(labelText: 'Nome do cliente', errorText: 'Digite três letras'),
              ),
              caps_ui.TextField(key: const Key('secret'), controller: secret, obscureText: true),
            ],
          ),
        ),
      ));
      expect(find.text('VENDA CONCLUÍDA'), findsOneWidget);
      expect(find.text('NOME DO CLIENTE'), findsOneWidget);
      expect(find.text('DIGITE TRÊS LETRAS'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('typed')), 'joão da silva');
      expect(typed.text, 'JOÃO DA SILVA');
      await tester.enterText(find.byKey(const Key('secret')), 'abc123');
      expect(secret.text, 'abc123');
    });
  });
}
