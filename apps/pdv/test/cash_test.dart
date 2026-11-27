import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/cash.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';

import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const supervisorId = '019a0000-0000-7000-8000-0000000000e1';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const adminId = '019a0000-0000-7000-8000-000000000008';
const dipirona = '019a0000-0000-7000-8000-000000000027';

final synced = DateTime(2026, 11, 23, 12);
late String pin;

PullItem user(String id, int code, String name, Map<String, Object?> limits, {bool admin = false}) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': admin, 'roles': const [], 'permissions': const ['sales.sell'], 'limits': limits, 'pin_hash': pin,
});

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'fixed_seller_id': operatorId,
      }),
      user(operatorId, 3, 'Operador Centro', const {'cash_withdrawal': 100}),
      user(supervisorId, 4, 'Supervisora Bia', const {'cash_withdrawal': 500}),
      user(managerId, 2, 'Gerente Centro', const {'cash_withdrawal': 2000}),
      user(adminId, 1, 'Administrador', const {'cash_withdrawal': null}, admin: true),
      PullItem(type: 'product', id: dipirona, data: {
        'code': 1, 'name': 'Dipirona 500 mg', 'status': 'active', 'price': 100, 'fraction_quantity': 1, 'batch_required': false,
        'barcodes': [
          {'id': '019a0000-0000-7001-8000-000000000027', 'code': '7890000000017', 'is_primary': true, 'fraction_quantity': null},
        ],
        'taxes': const [],
      }),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
    ]),
    now: synced,
  );
  return database;
}

void main() {
  late LocalDatabase database;
  late FakePrinter printer;
  late DateTime now;
  late PosController controller;
  late int shiftClosedCalls;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() {
    database = seeded();
    printer = FakePrinter();
    now = synced.add(const Duration(minutes: 5));
    shiftClosedCalls = 0;
    controller = PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => printer,
      terminalNumber: () => 1,
      clock: () => now,
      onShiftClosed: () async => shiftClosedCalls += 1,
    );
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  /// Turno com R$ 100 de fundo e uma venda de R$ 1.000 em dinheiro: R$ 1.100 na gaveta.
  Future<void> ready() async {
    await controller.login('3', '2468');
    controller.openShift(10000);
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, 10000);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 100000));
    await controller.finish();
    expect(controller.notice, isNull);
  }

  List<Map<String, Object?>> outbox(String kind) =>
      database.nextOutboxBatch().where((item) => item.kind == kind).map((item) => item.payload).toList();

  test('terminal com vendedor padrão: depois da venda, ele já entra e a tela não bloqueia', () async {
    await ready();
    expect(controller.sellerLock, isFalse);
    expect(controller.cart.seller?.id, operatorId);
  });

  testWidgets('terminal com vendedor padrão: sem tela preta e sem o botão de trocar', (tester) async {
    await tester.runAsync(ready);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('seller-lock')), findsNothing);
    expect(find.byKey(const Key('seller-band')), findsOneWidget);
    expect(find.byKey(const Key('seller-change')), findsNothing);
    expect(findText('Vendedor padrão do terminal'), findsOneWidget);
  });

  group('regras', () {
    test('limite de sangria: administrador sem teto, sem perfil com limite é zero', () {
      LocalUser person(Map<String, double?> limits, {bool admin = false}) => LocalUser(
        id: operatorId, code: 9, name: 'X', isAdmin: admin, permissions: const [], limits: limits,
      );
      expect(withdrawalLimitCents(person({'cash_withdrawal': 150.5})), 15050);
      expect(withdrawalLimitCents(person({})), 0);
      expect(withdrawalLimitCents(person({'cash_withdrawal': null})), isNull);
      expect(withdrawalLimitCents(person({'cash_withdrawal': 10}, admin: true)), isNull);
      expect(withdrawalNeedsRelease(person({'cash_withdrawal': 100}), 10000), isFalse);
      expect(withdrawalNeedsRelease(person({'cash_withdrawal': 100}), 10001), isTrue);
    });
  });

  group('sangria em três níveis', () {
    test('até o limite, o operador faz sozinho; sai o comprovante com as assinaturas', () async {
      await ready();
      expect(database.cashInDrawerCents(controller.session!.id), 110000);
      expect(await controller.withdraw(10000, '  Envelope do cofre '), isTrue);
      expect(controller.info, 'Sangria de R\$ 100,00 registrada.');
      expect(database.cashInDrawerCents(controller.session!.id), 100000);
      final payload = outbox('cash_movement').single;
      expect(payload, containsPair('kind', 'withdrawal'));
      expect(payload, containsPair('amount', 100.0));
      expect(payload, containsPair('reason', 'Envelope do cofre'));
      expect(payload, containsPair('operator_id', operatorId));
      expect(payload['released_by'], isNull);
      expect(payload['cash_session_id'], controller.session!.id);
      final receipt = printer.printed['sangria']!.map((line) => line.text).join('\n');
      expect(receipt, contains('SANGRIA'));
      expect(receipt, contains('Motivo: Envelope do cofre'));
      expect(receipt, contains('Quem recebeu o dinheiro'));
    });

    test('acima do limite: supervisor libera; acima do supervisor, o gerente', () async {
      await ready();
      expect(await controller.withdraw(30000, 'Envelope'), isFalse);
      expect(outbox('cash_movement'), isEmpty);
      // O próprio operador não libera.
      expect(await controller.releaseWithdrawal(30000, 'Envelope', '3', '2468'), isFalse);
      expect(noticeCode(), 'FA992');
      expect(await controller.releaseWithdrawal(30000, 'Envelope', '4', '2468'), isTrue);
      expect(outbox('cash_movement').single['released_by'], supervisorId);
      expect(printer.printed['sangria']!.map((line) => line.text), contains('Liberada por: Supervisora Bia'));

      expect(await controller.withdraw(80000, 'Banco'), isFalse);
      expect(await controller.releaseWithdrawal(80000, 'Banco', '4', '2468'), isFalse);
      expect(noticeCode(), 'FA992');
      expect(await controller.releaseWithdrawal(80000, 'Banco', '4', '9999'), isFalse);
      expect(noticeCode(), 'FA966');
      expect(await controller.releaseWithdrawal(80000, 'Banco', '2', '2468'), isTrue);
      expect(outbox('cash_movement').map((p) => p['released_by']), [supervisorId, managerId]);
    });

    test('não retira mais do que a gaveta, exige valor e motivo, e não mexe no caixa no meio da venda', () async {
      await ready();
      expect(await controller.withdraw(110001, 'Tudo'), isNull);
      expect(noticeCode(), 'FA993');
      expect(await controller.releaseWithdrawal(110001, 'Tudo', '2', '2468'), isFalse);
      expect(noticeCode(), 'FA993');
      expect(await controller.withdraw(0, 'Nada'), isNull);
      expect(noticeCode(), 'FA994');
      expect(await controller.withdraw(1000, '   '), isNull);
      expect(noticeCode(), 'FA994');
      expect(await controller.supply(0, 'Troco'), isFalse);
      expect(noticeCode(), 'FA994');
      controller.scan('7890000000017');
      expect(await controller.withdraw(1000, 'Envelope'), isNull);
      expect(noticeCode(), 'FA998');
      expect(await controller.supply(1000, 'Troco'), isFalse);
      expect(noticeCode(), 'FA998');
      expect(outbox('cash_movement'), isEmpty);
    });

    test('suprimento entra na gaveta e não pede liberação, mesmo grande', () async {
      await ready();
      expect(await controller.supply(500000, 'Troco do cofre'), isTrue);
      expect(database.cashInDrawerCents(controller.session!.id), 610000);
      expect(outbox('cash_movement').single, containsPair('kind', 'supply'));
      expect(printer.printed['suprimento']!.map((line) => line.text), contains('SUPRIMENTO'));
      // Com o suprimento, a sangria grande cabe na gaveta (e o administrador não tem teto).
      expect(await controller.withdraw(600000, 'Banco'), isFalse);
      expect(await controller.releaseWithdrawal(600000, 'Banco', '1', '2468'), isTrue);
    });
  });

  group('fechamento cego', () {
    test('exige todas as formas, sobe só o contado e volta para a entrada', () async {
      await ready();
      final sessionId = controller.session!.id;
      expect(await controller.closeShift({'cash': 110000, 'credit_card': 0, 'debit_card': 0}), isFalse);
      expect(noticeCode(), 'FA997');
      expect(await controller.closeShift({'cash': -1, 'credit_card': 0, 'debit_card': 0, 'pix': 0}), isFalse);
      expect(noticeCode(), 'FA997');
      controller.scan('7890000000017');
      expect(await controller.closeShift({'cash': 1, 'credit_card': 0, 'debit_card': 0, 'pix': 0}), isFalse);
      expect(noticeCode(), 'FA998');
      controller.remove(controller.cart.lines.single);
      // Fechamento recusado não é momento de atualizar.
      expect(shiftClosedCalls, 0);

      expect(await controller.closeShift({'cash': 109500, 'credit_card': 0, 'debit_card': 0, 'pix': 0}, note: ' Faltou troco '), isTrue);
      expect(controller.operator, isNull);
      expect(controller.session, isNull);
      expect(controller.info, contains('Caixa fechado'));
      // Caixa fechado: a atualização baixada pode ser aplicada agora.
      expect(shiftClosedCalls, 1);
      expect(database.openCashSession, isNull);
      expect(outbox('cash_session_close').single, {
        'cash_session_id': sessionId,
        'closed_by': operatorId,
        'closed_at': now.toUtc().toIso8601String(),
        'counts': {'cash': 1095.0, 'credit_card': 0.0, 'debit_card': 0.0, 'pix': 0.0},
        'note': 'Faltou troco',
      });
      final receipt = printer.printed['fechamento']!.map((line) => line.text).join('\n');
      expect(receipt, contains('FECHAMENTO DE CAIXA'));
      expect(receipt, contains('R\$ 1.095,00'));
      // Cego: o comprovante não traz o esperado nem a diferença.
      expect(receipt, isNot(contains('1.100,00')));
      expect(receipt.toLowerCase(), isNot(contains('esperado')));
      // O próximo operador abre outro turno.
      await controller.login('3', '2468');
      expect(controller.session, isNull);
      expect(controller.info, isNull);
    });
  });

  group('tela', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    }

    testWidgets('sangria acima do limite pede quem libere na mesma janela', (tester) async {
      await tester.runAsync(ready);
      await pump(tester);
      await tester.tap(find.byKey(const Key('cash-withdrawal')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cash-amount')), '300,00');
      await tester.enterText(find.byKey(const Key('cash-reason')), 'Envelope');
      await tester.tap(find.byKey(const Key('cash-confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cash-release-hint')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('cash-release-code')), '4');
      await tester.enterText(find.byKey(const Key('cash-release-pin')), '2468');
      await tester.tap(find.byKey(const Key('cash-confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cash-movement-dialog')), findsNothing);
      expect(findText('Sangria de R\$ 300,00 registrada.'), findsOneWidget);
    });

    testWidgets('fechamento só pelo teclado: Enter passa de forma em forma e, no fim, fecha', (tester) async {
      await tester.runAsync(ready);
      await pump(tester);
      await tester.tap(find.byKey(const Key('close-shift')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('count-cash')));
      await tester.pump();
      for (final (method, value, next) in [
        ('cash', '1100', 'credit_card'),
        ('credit_card', '0', 'debit_card'),
        ('debit_card', '0', 'pix'),
      ]) {
        await tester.enterText(find.byKey(Key('count-$method')), value);
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pump();
        final editable = tester.widget<EditableText>(find.descendant(of: find.byKey(Key('count-$next')), matching: find.byType(EditableText)));
        expect(editable.focusNode.hasFocus, isTrue, reason: 'Enter em $method deveria ir para $next');
      }
      await tester.enterText(find.byKey(const Key('count-pix')), '0');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      // Observação (opcional): o Enter nela conclui o preenchimento.
      expect(find.byKey(const Key('close-shift-confirm-text')), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('close-shift-confirm-text')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('close-shift-dialog')), findsNothing);
    });

    testWidgets('fechamento pede confirmação e não mostra o esperado', (tester) async {
      await tester.runAsync(ready);
      await pump(tester);
      await tester.tap(find.byKey(const Key('close-shift')));
      await tester.pumpAndSettle();
      final submit = find.byKey(const Key('close-shift-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      for (final (method, value) in [('cash', '1100'), ('credit_card', '0'), ('debit_card', '0'), ('pix', '0')]) {
        await tester.enterText(find.byKey(Key('count-$method')), value);
      }
      await tester.pump();
      expect(findTextContaining('1.100'), findsNothing);
      await tester.tap(submit);
      await tester.pump();
      expect(find.byKey(const Key('close-shift-confirm-text')), findsOneWidget);
      expect(findTextContaining('Dinheiro R\$ 1.100,00'), findsOneWidget);
      await tester.tap(submit);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('close-shift-dialog')), findsNothing);
      expect(find.byKey(const Key('login-info')), findsOneWidget);
      expect(find.byKey(const Key('login-code')), findsOneWidget);
    });
  });
}
