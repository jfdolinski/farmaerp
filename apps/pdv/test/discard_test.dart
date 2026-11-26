import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/display_settings.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_test.dart' show FakePrinter, hashFor;

// Parte A do lote de 26/11: descartar a venda em andamento ("Limpar tela" no orçamento, "Cancelar
// venda" no caixa e no autoatendimento), uma permissão por tela, e a liberação do supervisor.

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const clerkId = '019a0000-0000-7000-8000-0000000000c1';
const supervisorId = '019a0000-0000-7000-8000-00000000000d';
const dipirona = '019a0000-0000-7000-8000-000000000027';

final synced = DateTime(2026, 11, 26, 10);
late String pin;

PullItem user(String id, int code, String name, List<String> permissions) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions, 'limits': const {}, 'pin_hash': pin,
});

LocalDatabase seeded(String profile) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'last_quote_number': 3,
        'terminal_profile': profile,
        'seller_pin_required': false,
        'quote_validity_days': 0,
      }),
      // O operador cancela no caixa só com o supervisor; o balconista limpa o orçamento sozinho.
      user(operatorId, 3, 'Operador Centro', const ['sales.sell', 'sales.quote', 'pdv.quote_clear']),
      user(clerkId, 6, 'Balconista Ana', const ['sales.quote', 'pdv.quote_clear']),
      user(supervisorId, 2, 'Gerente Centro', const ['sales.sell', 'sales.quote', 'pdv.sale_cancel', 'pdv.self_service_cancel']),
      PullItem(type: 'product', id: dipirona, data: {
        'code': 1, 'name': 'Dipirona 500 mg', 'status': 'active', 'price': 12.9, 'fraction_quantity': 1, 'batch_required': false,
        'controlled_class': null, 'max_discount': 20,
        'barcodes': [
          {'id': dipirona.replaceFirst('7000', '7001'), 'code': '7890000000017', 'is_primary': true, 'fraction_quantity': null},
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
  late PosController controller;
  late int saved;
  final now = synced.add(const Duration(minutes: 5));

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  PosController build(String profile) {
    database = seeded(profile);
    saved = 0;
    return PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => FakePrinter(),
      terminalNumber: () => 1,
      clock: () => now,
      onSaleSaved: () => saved += 1,
    );
  }

  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');
  List<Map<String, dynamic>> discards() =>
      database.nextOutboxBatch().where((item) => item.kind == 'cart_discard').map((item) => item.payload).toList();

  /// Caixa com o operador e dois itens (o vendedor é pedido a cada venda).
  Future<void> cashierWithItems(String profile, {String login = '3'}) async {
    controller = build(profile);
    await controller.login(login, '2468');
    controller.openShift(0);
    await controller.identifySeller('6');
    controller.scan('7890000000017');
    controller.scan('7890000000017');
  }

  test('caixa: o operador sem a permissão precisa do supervisor; descartado, sobe o registro e a tela fica limpa', () async {
    await cashierWithItems('cashier');
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 1000));
    expect([controller.screen, controller.discardPermission, controller.discardLabel], ['cashier', 'pdv.sale_cancel', 'Cancelar venda']);
    expect(controller.can('pdv.sale_cancel'), isFalse);

    // Sem supervisor, PIN errado, ou quem não tem a permissão: nada sai da tela.
    expect(await controller.discardCart(), isFalse);
    expect(noticeCode(), 'FA966');
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '1111'), isFalse);
    expect(await controller.discardCart(supervisorCode: '6', supervisorPin: '2468'), isFalse);
    expect(noticeCode(), 'FA757');
    expect([controller.cart.lines.single.quantityMilli, discards()], [2000, isEmpty]);

    final before = saved;
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '2468'), isTrue);
    expect(controller.cart.isEmpty, isTrue);
    expect(controller.cart.payments, isEmpty);
    expect(controller.paying, isFalse);
    expect(controller.seller, isNull);
    expect(controller.info, 'Venda cancelada.');
    // Sobe logo (a fila é acionada como no fim da venda).
    expect(saved, before + 1);
    final record = discards().single;
    expect(record, {
      'id': record['id'], 'screen': 'cashier', 'user_id': operatorId, 'authorized_by': supervisorId,
      'items_count': 1, 'total': 25.8, 'discarded_at': now.toUtc().toIso8601String(),
    });
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7').hasMatch(record['id'] as String), isTrue);
    // Tela vazia: nada a descartar.
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '2468'), isFalse);
    expect(discards(), hasLength(1));
  });

  test('caixa: quem tem a permissão descarta sozinho, sem supervisor', () async {
    await cashierWithItems('cashier', login: '2');
    expect(controller.can('pdv.sale_cancel'), isTrue);
    expect(await controller.discardCart(), isTrue);
    expect(discards().single, containsPair('authorized_by', null));
    expect(discards().single, containsPair('user_id', supervisorId));
  });

  test('autoatendimento: permissão própria; a de limpar orçamento não vale aqui', () async {
    await cashierWithItems('self_service');
    expect([controller.screen, controller.discardPermission, controller.discardLabel], ['self_service', 'pdv.self_service_cancel', 'Cancelar venda']);
    expect(await controller.discardCart(supervisorCode: '6', supervisorPin: '2468'), isFalse);
    expect(noticeCode(), 'FA757');
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '2468'), isTrue);
    expect(discards().single, containsPair('screen', 'self_service'));
    expect(discards().single, containsPair('authorized_by', supervisorId));
  });

  test('autoatendimento: sempre código e PIN, mesmo com o turno aberto por quem tem a permissão; ele mesmo pode liberar', () async {
    await cashierWithItems('self_service', login: '2');
    expect(controller.can('pdv.self_service_cancel'), isTrue);
    expect(controller.discardNeedsRelease, isTrue);
    // Um toque do cliente não cancela.
    expect(await controller.discardCart(), isFalse);
    expect(controller.cart.isEmpty, isFalse);
    // Quem abriu o turno digita o código e o PIN: vale, e o registro fica só com ele.
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '2468'), isTrue);
    expect(discards().single, containsPair('user_id', supervisorId));
    expect(discards().single, containsPair('authorized_by', null));
  });

  test('no caixa, quem abriu o turno com a permissão não precisa de código', () async {
    await cashierWithItems('cashier', login: '2');
    expect(controller.discardNeedsRelease, isFalse);
  });

  test('orçamento: "Limpar tela" com a permissão do vendedor; o próximo vendedor se identifica de novo', () async {
    controller = build('quote');
    await controller.identifySeller('6');
    controller.scan('7890000000017');
    expect([controller.screen, controller.discardPermission, controller.discardLabel], ['quote', 'pdv.quote_clear', 'Limpar tela']);
    expect(await controller.discardCart(), isTrue);
    expect(controller.info, 'Tela limpa.');
    expect(controller.seller, isNull);
    expect(discards().single, containsPair('user_id', clerkId));
    expect(discards().single, containsPair('screen', 'quote'));
  });

  test('liberação de um cadastro: precisa da permissão e de outra pessoa', () async {
    controller = build('cashier');
    await controller.login('2', '2468');
    expect(await controller.authorize('pdv.customer_create', '6', '2468'), isNull);
    expect(noticeCode(), 'FA757');
    // O próprio operador não libera para si.
    expect(await controller.authorize('pdv.sale_cancel', '2', '2468'), isNull);
    expect(noticeCode(), 'FA982');
    expect((await controller.authorize('pdv.quote_clear', '6', '2468'))?.id, clerkId);
  });

  testWidgets('tela: o botão aparece com itens; sem a permissão, o diálogo pede o supervisor', (tester) async {
    await tester.runAsync(() => cashierWithItems('cashier'));
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('discard-cart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('release-code')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('release-code')), '2');
    await tester.enterText(find.byKey(const Key('release-pin')), '2468');
    await tester.tap(find.byKey(const Key('release-confirm')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(controller.cart.isEmpty, isTrue);
    expect(find.byKey(const Key('discard-cart')), findsNothing);
    expect(find.byKey(const Key('release-code')), findsNothing);
  });

  testWidgets('tela do orçamento: quem tem a permissão só confirma', (tester) async {
    controller = build('quote');
    await tester.runAsync(() => controller.identifySeller('6'));
    controller.scan('7890000000017');
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('discard-cart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('release-code')), findsNothing);
    await tester.tap(find.byKey(const Key('release-confirm')));
    await tester.pumpAndSettle();
    expect(controller.cart.isEmpty, isTrue);
  });

  test('tema: cards com sombra forte e contorno, também no tema pintado pelo tipo do terminal', () {
    for (final kind in TerminalKind.values) {
      final theme = DisplaySettings.themeFor(color: 'teal', kind: kind);
      expect(theme.cardTheme.elevation, 6);
      expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
      final tinted = DisplaySettings.tinted(ThemeData(), 'teal', kind);
      expect(tinted.cardTheme.elevation, 6);
    }
  });
}
