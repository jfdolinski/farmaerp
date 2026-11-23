// Ponta a ponta com a API e o banco reais. Roda só com PDV_E2E_API apontando para uma API local
// com o seed de desenvolvimento (ex.: http://localhost:3001); sem a variável, fica de fora.
import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/controlled.dart';
import 'package:farmaerp_pdv/pos/discount.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/receipt.dart';
import 'package:farmaerp_pdv/sync/sync_service.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/terminal/terminal_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'app_test.dart' show MemoryStore;

final _api = Platform.environment['PDV_E2E_API'];
const _branch = '019a0000-0000-7000-8000-000000000005';
const _dipirona = '019a0000-0000-7000-8000-000000000027';
const _demoCustomer = '019a0000-0000-7000-8000-000000000032';

void main() {
  test(
    'terminal novo faz a carga inicial e recebe a mudança de preço',
    () async {
      final base = _api!;
      final host = Uri.parse(base).host;
      if (!['localhost', '127.0.0.1'].contains(host)) {
        fail('O teste de ponta a ponta só roda contra a API local.');
      }
      Future<Map<String, dynamic>> admin(String path, Map<String, Object?> body, {String? token}) async {
        final response = await http.post(
          Uri.parse('$base$path'),
          headers: {'Content-Type': 'application/json', 'Authorization': ?(token == null ? null : 'Bearer $token')},
          body: jsonEncode(body),
        );
        expect(response.statusCode, inInclusiveRange(200, 299), reason: '$path: ${response.body}');
        return response.body.isEmpty ? {} : jsonDecode(response.body) as Map<String, dynamic>;
      }

      // Credenciais do seed de desenvolvimento.
      final session = (await admin('/auth/login', {
        'email': 'admin@farmaerp.test',
        'password': 'farmaerp-dev-123',
      }))['token'] as String;

      final client = HttpTerminalApi(baseUrl: base);
      final identity = await TerminalIdentity.loadOrCreate(MemoryStore());
      final pairing = await client.createPairing(
        publicKey: identity.publicKey,
        signature: await identity.sign('farmaerp-terminal-pairing:${identity.publicKey}'),
        platform: 'windows',
        deviceName: 'CAIXA-E2E',
        appVersion: '0.1.0',
        keyStorage: 'system',
      );
      final terminalId = (await admin('/admin/pairing/${pairing.code}/claim', {'branchId': _branch}, token: session))['terminalId']
          as String;
      await admin(
        '/admin/terminals/$terminalId/approve',
        {'name': 'Caixa E2E ${DateTime.now().millisecondsSinceEpoch}', 'profile': 'cashier'},
        token: session,
      );
      final challenge = await client.challenge(terminalId);
      final token = await client.token(
        challenge: challenge,
        signature: await identity.sign('farmaerp-terminal-auth:$challenge'),
      );

      final database = LocalDatabase.inMemory();
      addTearDown(database.close);
      final sync = SyncService(api: client, database: database);
      try {
        await sync.pull(token.value);
        expect(sync.initialLoadDone, isTrue);
        final loaded = database.productByBarcode('7890000000017')!;
        expect(loaded.id, _dipirona);
        expect(loaded.priceCents, 1290);
        expect(database.counts()['app_user'], greaterThan(0));
        expect(database.counts()['fiscal_series'], 2);

        await admin('/admin/products/$_dipirona/prices', {'branchId': _branch, 'price': 10.75, 'reason': 'Teste E2E'}, token: session);
        await sync.pull(token.value);
        expect(database.productByBarcode('7890000000017')?.priceCents, 1075);

        // Subida: um aviso do PDV chega à central; o reenvio não duplica.
        database.enqueueLog({
          'level': 'warn',
          'time': DateTime.now().toUtc().toIso8601String(),
          'msg': 'Teste E2E da subida',
          'error_code': 'FA001',
          'version': '0.2.0',
        }, now: DateTime.now());
        final pending = database.nextOutboxBatch();
        await sync.push(token.value);
        expect(database.outboxPending, 0);
        expect(database.debugSelect('SELECT result FROM outbox').single['result'], 'applied');
        final again = await client.push(accessToken: token.value, items: pending);
        expect(again.single.status, 'duplicate');

        // Cliente: busca mascarada, escolha completa e, depois, a descida acompanha o cadastro.
        final customers = CustomerService(api: client, database: database, accessToken: () async => token.value);
        final found = await customers.search('demonstra');
        expect(found.online, isTrue);
        final demo = found.customers.singleWhere((c) => c.id == _demoCustomer);
        expect(demo.documentMasked, '111.***.***-35');
        final chosen = await customers.select(_demoCustomer);
        expect(chosen['document'], '11144477735');
        await sync.pull(token.value);
        expect(database.customerById(_demoCustomer)?['name'], 'Cliente Demonstração');

        // Caixa: PIN do seed (o hash desceu na carga), turno, venda e subida até a central.
        // O número do terminal vem do sinal de vida, como no app.
        final terminalNumber = await client.heartbeat(accessToken: token.value, appVersion: '0.1.0');
        final printer = _MemoryPrinter();
        final pos = PosController(
          database: database,
          auth: PosAuth(database: database),
          printer: () => printer,
          terminalNumber: () => terminalNumber,
          customers: customers,
          networkStock: (productId) => client.networkStock(accessToken: token.value, productId: productId),
        );
        await pos.login('3', '2468');
        expect(pos.notice, isNull);
        pos.openShift(10000);
        pos.scan('7890000000017');
        // Estoque nas filiais, com internet.
        final network = await pos.stockElsewhere(pos.cart.lines.single.product);
        expect(network!.first['own'], isTrue);
        // Desconto de 5%: passa do limite do operador (0); o Gerente Centro (código 2, limite 10%) libera.
        final line = pos.cart.lines.single;
        final discount = (line.grossCents * 5 / 100).round();
        expect(pos.applyDiscount(line, discount), DiscountNeed.release);
        expect(await pos.releaseDiscount(line, discount, '2', '1357', 'Teste E2E'), isTrue);
        await pos.selectCustomer(_demoCustomer);
        expect(pos.cart.customer?.name, 'Cliente Demonstração');
        pos.startPayment();
        pos.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2000));
        await pos.finish();
        final saleCode = pos.lastSale!.code;
        expect(printer.printed, [saleCode]);
        await sync.push(token.value);
        expect(database.outboxPending, 0);
        expect(database.debugSelect("SELECT result FROM outbox WHERE kind = 'sale'").single['result'], 'applied');
        final sales = await http.get(
          Uri.parse('$base/admin/sales'),
          headers: {'Authorization': 'Bearer $session'},
        );
        final listed = (jsonDecode(sales.body) as List).cast<Map<String, dynamic>>().where((row) => row['code'] == saleCode).toList();
        expect(listed, hasLength(1));
        expect(listed.single['alert_count'], 0);
        expect(listed.single['customer_name'], 'Cliente Demonstração');
        final releases = await http.get(
          Uri.parse('$base/admin/supervisor-releases?action=sales.discount'),
          headers: {'Authorization': 'Bearer $session'},
        );
        expect(
          (jsonDecode(releases.body) as List).cast<Map<String, dynamic>>().where((row) => row['reason'] == 'Teste E2E'),
          hasLength(1),
        );

        // Controlado do seed (Clonazepam, lista B1): receita, comprador e lote; o administrador
        // (código 1) tem a permissão de liberar. Na central, a lista mostra o documento mascarado.
        pos.scan('7890000000055');
        expect(pos.pendingControlled, isNotNull);
        final batches = pos.controlledBatches(pos.pendingControlled!.product);
        expect(batches.first.number, 'CLZ01');
        final today = DateTime.now();
        final released = await pos.releaseControlled(
          form: PrescriptionForm(
            type: PrescriptionType.notificationB,
            number: 'E2E-001',
            date: today,
            prescriberName: 'Dra. Fictícia E2E',
            prescriberNumber: '654321',
            prescriberState: 'SP',
            buyerName: 'Comprador Fictício E2E',
            buyerDocument: '987654321',
            buyerIssuer: 'SSP',
            buyerState: 'SP',
          ),
          batchId: batches.first.id,
          quantityMilli: 1000,
          code: '1',
          pin: '2580',
        );
        expect(released, isTrue, reason: pos.notice?.message);
        pos.startPayment();
        pos.addPayment(Payment(method: PaymentMethod.pix, amountCents: pos.cart.totalCents));
        await pos.finish();
        final controlledCode = pos.lastSale!.code;
        await sync.push(token.value);
        expect(database.debugSelect("SELECT result FROM outbox WHERE kind = 'sale' ORDER BY sequence DESC LIMIT 1").single['result'], 'applied');
        final controlled = await http.get(Uri.parse('$base/admin/controlled'), headers: {'Authorization': 'Bearer $session'});
        final dispensed = (jsonDecode(controlled.body) as List).cast<Map<String, dynamic>>().where((row) => row['sale_code'] == controlledCode).single;
        expect(dispensed['status'], 'complete');
        expect(dispensed['batch_number'], 'CLZ01');
        expect(dispensed['buyer_document_masked'], '******321');
        expect(controlled.body, isNot(contains('987654321')));
      } finally {
        await admin('/admin/products/$_dipirona/prices', {'branchId': _branch, 'price': null}, token: session);
        await admin('/admin/terminals/$terminalId/revoke', {'reason': 'Fim do teste E2E'}, token: session);
      }
      // Revogado não baixa mais nada, mesmo com o token ainda válido.
      await expectLater(
        sync.pull(token.value),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA305')),
      );
    },
    skip: _api == null ? 'defina PDV_E2E_API para rodar contra a API local' : false,
  );
}

class _MemoryPrinter implements ReceiptPrinter {
  final printed = <String>[];

  @override
  String get description => 'memória';

  @override
  Future<void> print(String saleCode, List<ReceiptLine> lines) async => printed.add(saleCode);
}
