import 'package:farmaerp_pdv/core/text_fold.dart';
import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/display_settings.dart';
import 'package:farmaerp_pdv/pos/focus_kit.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart' show ApiException;
import 'package:farmaerp_pdv/ui/caps.dart' show caps;
import 'package:farmaerp_pdv/ui/date_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';

import 'app_test.dart' show FakeApi;
import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const plainId = '019a0000-0000-7000-8000-0000000000c3';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const dorflex = '019a0000-0000-7000-8000-000000000028';
const clonazepam = '019a0000-0000-7000-8000-000000000033';

final synced = DateTime(2026, 11, 24, 10);
late String pin;

PullItem product(String id, int code, String name, String barcode, {String? ingredient, String? manufacturer, String? controlledClass}) => PullItem(
  type: 'product',
  id: id,
  data: {
    'code': code, 'name': name, 'status': 'active', 'price': 10, 'fraction_quantity': 1, 'batch_required': controlledClass != null,
    'active_ingredient': ingredient, 'manufacturer': manufacturer, 'controlled_class': controlledClass, 'max_discount': 15,
    'ms_registration': '1000000000001', 'ncm': '30049099', 'cest': '1300100',
    'barcodes': [
      {'id': id.replaceFirst('7000', '7001'), 'code': barcode, 'is_primary': true, 'fraction_quantity': null},
    ],
    'taxes': const [],
  },
);

LocalDatabase seeded({String profile = 'cashier'}) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'terminal_profile': profile,
      }),
      // Sem "Cadastrar cliente no PDV": precisa da liberação.
      PullItem(type: 'user', id: plainId, data: {
        'code': 6, 'name': 'Caixa Sem Cadastro', 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell'],
        'limits': const {}, 'pin_hash': pin,
      }),
      PullItem(type: 'user', id: managerId, data: {
        'code': 2, 'name': 'Gerente Centro', 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell', 'pdv.customer_create'],
        'limits': const {}, 'pin_hash': pin,
      }),
      PullItem(type: 'user', id: operatorId, data: {
        'code': 3, 'name': 'Operador Centro', 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell', 'pdv.customer_create'],
        'limits': const {'sale_discount': 5}, 'pin_hash': pin,
      }),
      product(dipirona, 1, 'Dipirona Sódica 500 mg', '7890000000017', ingredient: 'Dipirona', manufacturer: 'EMS'),
      product(dorflex, 2, 'Dorflex 36 comprimidos', '7890000000024', ingredient: 'Dipirona, orfenadrina e cafeína', manufacturer: 'Sanofi'),
      product(clonazepam, 4, 'Clonazepam 2 mg', '7890000000055', controlledClass: 'B1'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 10, 'batches': []}),
      const PullItem(type: 'stock', id: dorflex, data: {'quantity': 10, 'batches': []}),
      const PullItem(type: 'stock', id: clonazepam, data: {
        'quantity': 2,
        'batches': [{'id': '019a0000-0000-7000-8000-000000000036', 'number': 'CLZ01', 'expires_on': '2030-03-31', 'quantity': 2}],
      }),
    ]),
    now: synced,
  );
  return database;
}

/// O campo da chave está com o cursor?
bool focused(Key key) => find
    .descendant(of: find.byKey(key), matching: find.byType(EditableText))
    .evaluate()
    .any((element) => (element.widget as EditableText).focusNode.hasFocus);

void main() {
  late FakeApi api;
  late LocalDatabase database;
  late FakePrinter printer;
  late PosController controller;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() {
    api = FakeApi();
    database = seeded();
    printer = FakePrinter();
    controller = PosController(
      database: database,
      auth: PosAuth(database: database),
      printer: () => printer,
      terminalNumber: () => 3,
      customers: CustomerService(api: api, database: database, accessToken: () async => 't'),
    );
  });
  tearDown(() => database.close());

  group('busca de produto', () {
    test('texto sem acento e sem maiúsculas', () {
      expect(foldText('Dipirona SÓDICA 500mg, ação!'), 'dipirona sodica 500mg acao');
      expect(foldText(null), '');
    });

    test('o espaço vale como "%": pedaços na ordem, do meio da palavra também', () {
      List<int> codes(String query) => database.searchSaleProducts(query).map((p) => p.code).toList();
      expect(codes('dip 500'), [1]);
      expect(codes('pirona'), containsAll([1, 2]));
      expect(codes('SODICA'), [1]);
      expect(codes('sod 500 mg'), [1]);
      expect(codes('dor cafe'), [2]);
      // Começo de palavra (índice) vem antes do pedaço do meio.
      expect(codes('dipirona').first, 1);
      expect(codes('xyz'), isEmpty);
      expect(codes('   '), isEmpty);
    });

    test('consulta dos dados de cadastro', () {
      final data = database.productDetails(clonazepam)!;
      expect(data, containsPair('code', 4));
      expect(data, containsPair('ms_registration', '1000000000001'));
      expect(data, containsPair('controlled_class', 'B1'));
      expect(data, containsPair('batch_required', true));
      expect(data['barcodes'], [{'code': '7890000000055', 'primary': true, 'fraction_milli': null}]);
      expect(data['batches'], [{'number': 'CLZ01', 'expires_on': '2030-03-31', 'quantity_milli': 2000}]);
      expect(database.productDetails('019a0000-0000-7000-8000-0000000000ff'), isNull);
    });
  });

  group('fonte do PDV', () {
    test('tamanho e tipo ficam no terminal; valor fora da lista é ignorado', () {
      final settings = DisplaySettings(database);
      expect([settings.scale, settings.family], [1.0, '']);
      settings.update(scale: 1.3, family: 'Verdana');
      settings.update(scale: 7, family: 'Comic');
      final again = DisplaySettings(database);
      expect([again.scale, again.family], [1.3, 'Verdana']);
      expect(again.theme().textTheme.bodyMedium?.fontFamily, 'Verdana');
      again.update(family: '');
      expect(DisplaySettings(database).family, '');
    });

    testWidgets('o tamanho vale na tela toda', (tester) async {
      final settings = DisplaySettings(database)..update(scale: 1.4);
      late double scale;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => settings.apply(context, child!),
        home: Builder(builder: (context) {
          scale = MediaQuery.of(context).textScaler.scale(10) / 10;
          return const SizedBox();
        }),
      ));
      expect(scale, closeTo(1.4, 0.001));
    });
  });

  testWidgets('campo de número: entra com o valor selecionado', (tester) async {
    final text = TextEditingController(text: '150,00');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NumberField(key: const Key('n'), controller: text, decimal: true))));
    await tester.tap(find.byKey(const Key('n')));
    await tester.pump();
    await tester.pump();
    expect([text.selection.baseOffset, text.selection.extentOffset], [0, 6]);
    await tester.enterText(find.byKey(const Key('n')), '200');
    expect(text.text, '200');
  });

  group('foco no campo obrigatório', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller, appVersion: '1.2.3')));
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('entrada: PIN errado volta para o PIN; turno com o fundo de troco selecionado', (tester) async {
      await pump(tester);
      expect(focused(const Key('login-code')), isTrue);
      await tester.enterText(find.byKey(const Key('login-code')), '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(focused(const Key('login-pin')), isTrue);
      await tester.enterText(find.byKey(const Key('login-pin')), '1111');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(focused(const Key('login-pin')), isTrue);
      await tester.enterText(find.byKey(const Key('login-pin')), '2468');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(focused(const Key('opening-float')), isTrue);
      final float = tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('opening-float')), matching: find.byType(EditableText)));
      expect(float.controller.selection.extentOffset, float.controller.text.length);
      expect(float.controller.selection.baseOffset, 0);
    });

    testWidgets('venda: vendedor, leitura, pagamento e de volta ao vendedor; janela fechada volta para a leitura', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await pump(tester);
      expect(focused(const Key('seller-code')), isTrue);
      await tester.enterText(find.byKey(const Key('seller-code')), '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(focused(const Key('scan-field')), isTrue);
      await tester.enterText(find.byKey(const Key('scan-field')), '7890000000017');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(controller.cart.lines, hasLength(1));
      expect(focused(const Key('scan-field')), isTrue);

      // F4 abre o cliente; Esc fecha e o cursor volta para a leitura.
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await settle(tester);
      expect(focused(const Key('customer-query')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(focused(const Key('scan-field')), isTrue);

      // Pagamento: valor com o que falta, selecionado; depois de um parcial, de novo.
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await settle(tester);
      expect(focused(const Key('payment-amount')), isTrue);
      await tester.enterText(find.byKey(const Key('payment-amount')), '4,00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(focused(const Key('payment-amount')), isTrue);
      final amount = tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('payment-amount')), matching: find.byType(EditableText)));
      expect(amount.controller.text, '6,00');
      expect(amount.controller.selection.baseOffset, 0);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await tester.tap(find.byKey(const Key('finish')));
      await settle(tester);
      // Venda nova: pede o vendedor.
      expect(focused(const Key('seller-code')), isTrue);
    });

    testWidgets('venda concluída: tela preta com o troco pede o vendedor; só F6, F7 e F8 funcionam', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      await pump(tester);
      expect(find.byKey(const Key('seller-band')), findsOneWidget);
      expect(find.byKey(const Key('seller-lock')), findsNothing);
      await tester.enterText(find.byKey(const Key('scan-field')), '7890000000017');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await settle(tester);
      await tester.enterText(find.byKey(const Key('payment-amount')), '20,00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await tester.tap(find.byKey(const Key('finish')));
      await settle(tester);

      expect(controller.sellerLock, isTrue);
      expect(find.byKey(const Key('seller-lock')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('seller-lock-change'))).data, caps('R\$ 10,00'));
      expect(find.byKey(const Key('seller-lock-info')), findsOneWidget);
      // Cobre a tela toda, inclusive a barra de cima.
      expect(tester.getRect(find.byKey(const Key('seller-lock'))), tester.getRect(find.byType(MaterialApp)));
      expect(tester.getRect(find.byType(MaterialApp)).size, const Size(1500, 1000));
      expect(focused(const Key('seller-code')), isTrue);
      expect(find.byKey(const Key('seller-band')), findsNothing);

      // Atalhos da venda não fazem nada; o Esc não tira a tela preta.
      for (final key in [LogicalKeyboardKey.f2, LogicalKeyboardKey.f4, LogicalKeyboardKey.f9, LogicalKeyboardKey.f10, LogicalKeyboardKey.escape]) {
        await tester.sendKeyEvent(key);
        await settle(tester);
        expect(find.byKey(const Key('seller-lock')), findsOneWidget);
        expect(find.byKey(const Key('customer-query')), findsNothing);
        expect(find.byKey(const Key('return-dialog')), findsNothing);
        expect(focused(const Key('seller-code')), isTrue, reason: '$key');
      }
      // Sangria (F6) abre por cima e, ao fechar, o cursor volta para o vendedor.
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await settle(tester);
      expect(find.byKey(const Key('cash-movement-dialog')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const Key('cash-movement-dialog')), findsNothing);
      expect(focused(const Key('seller-code')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f7);
      await settle(tester);
      expect(find.byKey(const Key('cash-movement-dialog')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await settle(tester);
      expect(find.byKey(const Key('close-shift-dialog')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      // Código errado: o aviso aparece na própria tela preta.
      await tester.enterText(find.byKey(const Key('seller-code')), '999');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(find.byKey(const Key('seller-lock-notice')), findsOneWidget);
      expect(controller.sellerLock, isTrue);

      await tester.enterText(find.byKey(const Key('seller-code')), '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(controller.sellerLock, isFalse);
      expect(find.byKey(const Key('seller-lock')), findsNothing);
      expect(find.byKey(const Key('seller-band')), findsOneWidget);
      expect(focused(const Key('scan-field')), isTrue);
    });

    test('sair do caixa tira o bloqueio; sem venda concluída, não bloqueia', () async {
      await controller.login('3', '2468');
      controller.openShift(0);
      expect(controller.sellerLock, isFalse);
      await controller.identifySeller('3');
      controller.scan('7890000000017');
      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 1000));
      await controller.finish();
      expect(controller.sellerLock, isTrue);
      controller.logout();
      expect(controller.sellerLock, isFalse);
    });

    testWidgets('controlado: ao finalizar, o botão da receita recebe o foco', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      await pump(tester);
      await tester.enterText(find.byKey(const Key('scan-field')), '7890000000055');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      controller.startPayment();
      await settle(tester);
      final button = tester.widget<FilledButton>(find.byKey(const Key('controlled-open')));
      expect(button.focusNode?.hasFocus, isTrue);
      controller.cancelControlled();
      await settle(tester);
      expect(focused(const Key('scan-field')), isTrue);
    });
  });

  group('autocompletar', () {
    testWidgets('produto: sugere enquanto digita; setas escolhem e Enter adiciona; consulta do produto', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('scan-field')), 'di');
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.results, isEmpty);
      await tester.enterText(find.byKey(const Key('scan-field')), 'pirona');
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.results.map((p) => p.code), containsAll([1, 2]));
      expect(tester.widget<ListTile>(find.byKey(Key('result-${controller.results.first.code}'))).selected, isTrue);
      final second = controller.results[1].code;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.widget<ListTile>(find.byKey(Key('result-$second'))).selected, isTrue);

      await tester.tap(find.byKey(Key('info-result-$second')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('product-info')), findsOneWidget);
      expect(findText('30049099'), findsOneWidget);
      await tester.tap(findText('Fechar'));
      await tester.pumpAndSettle();

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(controller.cart.lines.single.product.code, second);
      expect(controller.results, isEmpty);
      // Código de barras não abre sugestão.
      await tester.enterText(find.byKey(const Key('scan-field')), '789000');
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.results, isEmpty);
    });

    testWidgets('cliente: cadastro na tela de vendas confere o CPF, usa o digitado na busca e já escolhe o cliente', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('customer-query')), '111.444.777-35');
      await tester.tap(find.byKey(const Key('customer-new')));
      await tester.pumpAndSettle();
      String text(String key) => tester.widget<TextField>(find.byKey(Key('customer-new-$key'))).controller!.text;
      expect(text('document'), '11144477735');

      // CPF errado e nome curto: nada vai para a central.
      await tester.enterText(find.byKey(const Key('customer-new-document')), '11144477736');
      await tester.enterText(find.byKey(const Key('customer-new-name')), 'Jo');
      await tester.tap(find.byKey(const Key('customer-new-save')));
      await tester.pumpAndSettle();
      expect(findText('CPF inválido'), findsOneWidget);
      expect(findText('Informe o nome completo'), findsOneWidget);
      expect(api.createdCustomers, isEmpty);

      // CPF já cadastrado: mensagem e atalho para buscar.
      await tester.enterText(find.byKey(const Key('customer-new-document')), '111.444.777-35');
      await tester.enterText(find.byKey(const Key('customer-new-name')), 'Ana Fictícia');
      api.createFailure = const ApiException('FA901');
      await tester.tap(find.byKey(const Key('customer-new-save')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('customer-new-error')), findsOneWidget);
      expect(find.byKey(const Key('customer-new-find')), findsOneWidget);

      api.createFailure = null;
      await tester.tap(find.byKey(const Key('customer-new-marketing')));
      await tester.enterText(find.byKey(const Key('customer-new-birth')), '20/05/1990');
      await tester.tap(find.byKey(const Key('customer-new-save')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(api.createdCustomers.single, containsPair('birthDate', '1990-05-20'));
      expect(api.createdCustomers.single['consents'], {'cashback': false, 'marketing': true});
      expect(controller.cart.customer?.name, caps('Ana Fictícia'));
      expect(find.byKey(const Key('customer-new-save')), findsNothing);
    });

    testWidgets('cliente: cadastro só pelo teclado, com a data digitada só com números', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('customer-new')));
      await tester.pumpAndSettle();
      bool hasFocus(String key) => tester
          .widget<EditableText>(find.descendant(of: find.byKey(Key('customer-new-$key')), matching: find.byType(EditableText)))
          .focusNode
          .hasFocus;
      await tester.tap(find.byKey(const Key('customer-new-name')));
      await tester.enterText(find.byKey(const Key('customer-new-name')), 'Bia Fictícia');
      for (final (next, value) in [('document', '111.444.777-35'), ('phone', '11987654321'), ('birth', '03021985')]) {
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pump();
        expect(hasFocus(next), isTrue, reason: 'Enter deveria ir para $next');
        await tester.enterText(find.byKey(Key('customer-new-$next')), value);
      }
      // Nascimento não pode ser no futuro: o calendário vai só até hoje.
      final birth = tester.widget<DateField>(find.byKey(const Key('customer-new-birth')));
      expect(birth.lastDate, isNotNull);
      expect(birth.lastDate!.isAfter(DateTime.now()), isFalse);
      // A caixa de marcação fica fora: o Enter na data já cadastra.
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(api.createdCustomers.single, containsPair('birthDate', '1985-02-03'));
      expect(controller.cart.customer?.name, caps('Bia Fictícia'));
    });

    testWidgets('cliente: sem a permissão, o cadastro pede a liberação e vai em nome de quem liberou', (tester) async {
      await tester.runAsync(() => controller.login('6', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('6'));
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('customer-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('customer-new-name')), findsNothing);
      // Desistir da liberação: o cadastro não abre.
      await tester.tap(find.byKey(const Key('release-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('customer-new-name')), findsNothing);
      await tester.tap(find.byKey(const Key('customer-new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('release-code')), '2');
      await tester.enterText(find.byKey(const Key('release-pin')), '2468');
      await tester.tap(find.byKey(const Key('release-confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('customer-new-document')), '111.444.777-35');
      await tester.enterText(find.byKey(const Key('customer-new-name')), 'Ana Fictícia');
      await tester.tap(find.byKey(const Key('customer-new-save')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(api.createdCustomers.single, containsPair('operatorId', managerId));
    });

    test('cliente: sem a permissão e sem liberação, nem chama a central', () async {
      await controller.login('6', '2468');
      expect(await controller.createCustomer(name: 'Ana Fictícia', document: '11144477735'), 'FA002');
      expect(api.createdCustomers, isEmpty);
    });

    test('cliente no terminal de orçamento: vai em nome do vendedor (não há operador)', () async {
      database.close();
      database = seeded(profile: 'quote');
      controller = PosController(
        database: database,
        auth: PosAuth(database: database),
        printer: () => printer,
        terminalNumber: () => 3,
        customers: CustomerService(api: api, database: database, accessToken: () async => 't'),
      );
      await controller.identifySeller('3');
      expect(await controller.createCustomer(name: 'Ana Fictícia', document: '11144477735'), isNull);
      expect(api.createdCustomers.single, containsPair('operatorId', operatorId));
    });

    testWidgets('cliente: o histórico abre pelo painel; sem internet avisa', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      const id = '019a0000-0000-7000-8000-000000000032';
      api.customerData[id] = {
        'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735', 'agreements': const [],
      };
      api.customerHistories[id] = {
        'sales_12m': 2, 'total_12m': '90.00', 'average_ticket': '45.00', 'last_purchase_at': '2026-11-20T15:00:00Z',
        'last_30_days': [
          {'sale_id': 's1', 'code': '1-000010', 'sold_at': '2026-11-20T15:00:00Z', 'branch_name': 'Loja Centro', 'total': '70.00', 'items': 2},
        ],
        'recurring': [
          {'product_id': 'p1', 'name': 'Losartana 50 mg', 'purchases': 2, 'quantity': '3', 'last_at': '2026-11-20T15:00:00Z'},
        ],
      };
      await tester.runAsync(() => controller.selectCustomer(id));
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('customer-history-open')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      // Tela toda: cartões com os números e tabelas com as compras e os produtos.
      final screen = tester.getSize(find.byKey(const Key('customer-history')));
      expect(screen, const Size(1500, 1000));
      final ticket = find.byKey(const Key('customer-history-ticket'));
      expect(find.descendant(of: ticket, matching: findText('Ticket médio (12 meses)')), findsOneWidget);
      expect(find.descendant(of: ticket, matching: findText('R\$ 45,00')), findsOneWidget);
      expect(findText('R\$ 90,00'), findsOneWidget);
      expect(findText('20/11/2026'), findsNWidgets(3));
      final recent = find.byKey(const Key('customer-history-recent'));
      for (final cell in ['1-000010', 'Loja Centro', '2', 'R\$ 70,00']) {
        expect(find.descendant(of: recent, matching: findText(cell)), findsOneWidget, reason: cell);
      }
      final recurring = find.byKey(const Key('customer-history-recurring'));
      expect(find.descendant(of: recurring, matching: find.byKey(const Key('customer-history-p1'))), findsOneWidget);
      expect(find.descendant(of: recurring, matching: findText('Losartana 50 mg')), findsOneWidget);
      expect(find.descendant(of: recurring, matching: findText('3')), findsOneWidget);
      await tester.tap(find.byKey(const Key('customer-history-close')));
      await tester.pumpAndSettle();

      api.historyFailure = const ApiException('FA001');
      await tester.tap(find.byKey(const Key('customer-history-open')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('customer-history-error')), findsOneWidget);
      expect(findTextContaining('A consulta precisa de internet.'), findsOneWidget);
    });

    testWidgets('cliente: busca sozinha a partir de 3 letras e Enter escolhe o marcado', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await tester.runAsync(() => controller.identifySeller('3'));
      api.searchResults.add(const CustomerSummary(
        id: '019a0000-0000-7000-8000-000000000032', code: 7, personType: 'individual', name: 'Cliente Demonstração',
      ));
      api.customerData['019a0000-0000-7000-8000-000000000032'] = {
        'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735', 'agreements': const [],
      };
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('customer-query')), 'de');
      await tester.pump(const Duration(milliseconds: 400));
      expect(api.searchQueries, isEmpty);
      await tester.enterText(find.byKey(const Key('customer-query')), 'dem');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(api.searchQueries, ['DEM']);
      expect(tester.widget<ListTile>(find.byKey(const Key('customer-7'))).selected, isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 40 && controller.cart.customer == null; i += 1) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(controller.cart.customer?.name, 'Cliente Demonstração', reason: '${controller.notice?.reference} ${api.searchQueries}');
      expect(focused(const Key('scan-field')), isTrue);
    });
  });

  testWidgets('barra inferior: loja, caixa, operador e turno, vendedor, internet, hora e versão', (tester) async {
    await tester.runAsync(() => controller.login('3', '2468'));
    controller.openShift(0);
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller, online: false, appVersion: '1.2.3')));
    await tester.pumpAndSettle();
    String text(String key) => tester.widget<Text>(find.byKey(Key('status-$key'))).data!;
    expect(text('loja'), caps('Loja Centro · Caixa 3'));
    expect(text('operador'), startsWith(caps('Operador: Operador Centro · turno desde ')));
    expect(text('vendedor'), caps('Vendedor: —'));
    expect(text('internet'), startsWith(caps('Sem internet: as vendas sobem quando voltar · 2 a enviar')));
    expect(text('versao'), caps('v1.2.3'));
    expect(find.byKey(const Key('status-agora')), findsOneWidget);
    // Não mostra valores do turno (o fechamento é cego).
    expect(find.descendant(of: find.byKey(const Key('pos-status-bar')), matching: findTextContaining('R\$')), findsNothing);
    await tester.runAsync(() => controller.identifySeller('3'));
    await tester.pumpAndSettle();
    expect(text('vendedor'), caps('Vendedor: Operador Centro'));
    expect(find.byKey(const Key('pos-offline')), findsNothing);
    // Pagamento não muda nada aqui.
    expect(Payment(method: PaymentMethod.cash, amountCents: 1).amountCents, 1);
  });
}
