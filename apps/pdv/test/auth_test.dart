import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';
import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const faceId = '019a0000-0000-7000-8000-0000000000f1';
const anyId = '019a0000-0000-7000-8000-0000000000f2';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const supervisorId = '019a0000-0000-7000-8000-0000000000f3';

late String pin;

PullItem user(String id, int code, String name, List<String> permissions, {String? mode}) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions,
  'limits': const {}, 'pin_hash': pin, 'auth_mode': ?mode,
});

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '1', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
      }),
      user(operatorId, 3, 'Operador Centro', const ['sales.sell']),
      user(faceId, 4, 'Operadora Câmera', const ['sales.sell'], mode: 'face'),
      user(anyId, 5, 'Operador Qualquer', const ['sales.sell'], mode: 'any'),
      user(managerId, 2, 'Gerente Centro', const ['sales.sell', 'users.release_login', 'users.biometrics']),
      user(supervisorId, 6, 'Supervisor Sem Liberação', const ['sales.sell']),
    ]),
    now: DateTime(2026, 11, 24, 10),
  );
  return database;
}

void main() {
  late LocalDatabase database;
  late DateTime now;
  late PosAuth auth;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() {
    database = seeded();
    now = DateTime(2026, 11, 24, 10, 5);
    auth = PosAuth(database: database, clock: () => now);
  });
  tearDown(() => database.close());

  List<Map<String, Object?>> events() =>
      database.nextOutboxBatch().where((item) => item.kind == 'auth_event').map((item) => item.payload).toList();
  Future<String?> codeOf(Future<Object?> Function() action) async {
    try {
      await action();
      return null;
    } on PosException catch (error) {
      return error.code;
    }
  }

  test('a forma de entrar desce da central; desconhecida vira PIN', () {
    expect(database.userByCode(4)!.authMode, 'face');
    expect(database.userByCode(5)!.authMode, 'any');
    expect(database.userByCode(3)!.authMode, 'pin');
    database.applyPage(PullPage(format: 3, until: '2', items: [user(operatorId, 3, 'Operador Centro', const ['sales.sell'], mode: 'senha')]), now: now);
    expect(database.userByCode(3)!.authMode, 'pin');
    expect(allowedMethods('any'), AuthMethod.values.toSet());
    expect(allowedMethods('fingerprint'), {AuthMethod.fingerprint});
    expect(allowedMethods('outra'), {AuthMethod.pin});
  });

  test('PIN: entrada, falha e bloqueio sobem como registro; quem é só câmera não entra com PIN', () async {
    final entered = await auth.verify('3', '2468', permission: 'sales.sell', purpose: AuthPurpose.login);
    expect(entered.id, operatorId);
    expect(await codeOf(() => auth.verify('3', '1111')), 'FA966');
    expect(await codeOf(() => auth.verify('99', '2468')), 'FA966');
    expect(await codeOf(() => auth.verify('4', '2468')), 'FA820');
    expect((await auth.verify('5', '2468', purpose: AuthPurpose.seller)).id, anyId);
    for (var i = 0; i < 3; i += 1) {
      await codeOf(() => auth.verify('3', '0000'));
    }
    expect(await codeOf(() => auth.verify('3', '0000')), 'FA967');
    final recorded = events();
    expect(recorded.map((e) => [e['user_id'], e['event'], e['purpose'], e['method']]), [
      [operatorId, 'success', 'login', 'pin'],
      [operatorId, 'failure', 'approval', 'pin'],
      [anyId, 'success', 'seller', 'pin'],
      [operatorId, 'failure', 'approval', 'pin'],
      [operatorId, 'failure', 'approval', 'pin'],
      [operatorId, 'failure', 'approval', 'pin'],
      [operatorId, 'locked', 'approval', 'pin'],
    ]);
    expect(recorded.first['occurred_at'], now.toUtc().toIso8601String());
    expect(recorded.first['authorized_by'], isNull);
    expect(recorded.every((e) => !e.containsKey('pin')), isTrue);
  });

  test('na entrada por código, quem não usa PIN precisa da liberação (com ou sem câmera)', () {
    expect(auth.needsRelease(database.userByCode(4)!), isTrue);
    expect(auth.needsRelease(database.userByCode(5)!), isFalse);
    expect(auth.needsRelease(database.userByCode(3)!), isFalse);
    final withCamera = PosAuth(database: database, available: const {AuthMethod.pin, AuthMethod.face});
    expect(withCamera.needsRelease(database.userByCode(4)!), isTrue);
    expect(withCamera.usableBy(database.userByCode(5)!), {AuthMethod.pin, AuthMethod.face});
  });

  test('liberação do gerente: registra os dois; sem a permissão, a mesma pessoa ou PIN errado, não', () async {
    expect(await codeOf(() => auth.release('4', '6', '2468')), 'FA821');
    expect(await codeOf(() => auth.release('2', '2', '2468')), 'FA821');
    expect(await codeOf(() => auth.release('4', '2', '1111')), 'FA966');
    expect(await codeOf(() => auth.release('99', '2', '2468')), 'FA966');
    final released = await auth.release('4', '2', '2468', permission: 'sales.sell');
    expect(released.id, faceId);
    final recorded = events();
    expect(recorded.last, containsPair('method', 'manager_release'));
    expect(recorded.last, containsPair('authorized_by', managerId));
    expect(recorded.last, containsPair('user_id', faceId));
    expect(recorded.last, containsPair('purpose', 'login'));
    // Antes: o supervisor conferiu o PIN (sucesso) mas não podia liberar; o gerente errou o PIN.
    expect(recorded.map((e) => [e['user_id'], e['event'], e['method']]).toList().sublist(0, 4), [
      [supervisorId, 'success', 'pin'],
      [managerId, 'success', 'pin'],
      [managerId, 'failure', 'pin'],
      [managerId, 'success', 'pin'],
    ]);
  });

  testWidgets('tela: código de quem só entra pela câmera troca o PIN pela liberação do gerente', (tester) async {
    final controller = PosController(
      database: database,
      auth: auth,
      printer: FakePrinter.new,
      terminalNumber: () => 1,
      clock: () => now,
    );
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    expect(find.byKey(const Key('login-pin')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('login-code')), '4');
    await tester.pump();
    expect(find.byKey(const Key('login-pin')), findsNothing);
    expect(find.byKey(const Key('login-release-hint')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('release-manager-code')), '2');
    await tester.enterText(find.byKey(const Key('release-manager-pin')), '2468');
    await tester.runAsync(() => controller.releaseLogin('4', '2', '2468'));
    await tester.pump();
    expect(controller.operator?.id, faceId);
    expect(findText('Abrir o caixa'), findsWidgets);
    controller.logout();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('login-code')), '3');
    await tester.pump();
    expect(find.byKey(const Key('login-pin')), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
