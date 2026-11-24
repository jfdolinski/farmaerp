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
          openQuotes: () => client.openQuotes(accessToken: token.value),
          findQuote: (key) => client.quote(accessToken: token.value, key: key),
          saleForReturn: (code) => client.saleForReturn(accessToken: token.value, code: code),
          returnDocument: (code) => client.returnDocument(accessToken: token.value, code: code),
          returnCredit: (code) => client.returnCredit(accessToken: token.value, code: code),
        );
        await pos.login('3', '2468');
        expect(pos.notice, isNull);
        pos.openShift(10000);
        // Cada venda pede o vendedor: o próprio Operador Centro atende.
        expect(await pos.identifySeller('3'), isTrue, reason: pos.notice?.message);
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
        expect(await pos.identifySeller('3'), isTrue);
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

        // Caixa: sangria acima do limite do operador (zero no seed) liberada pelo Gerente Centro e
        // fechamento cego. A central calcula o esperado e a retaguarda vê a conferência.
        final shift = pos.session!.id;
        expect(await pos.withdraw(5000, 'Envelope E2E'), isFalse);
        expect(await pos.releaseWithdrawal(5000, 'Envelope E2E', '2', '1357'), isTrue, reason: pos.notice?.message);
        expect(await pos.closeShift({'cash': 1000, 'credit_card': 0, 'debit_card': 0, 'pix': 0}, note: 'Teste E2E'), isTrue);
        await sync.push(token.value);
        expect(database.outboxPending, 0);
        expect(
          database.debugSelect("SELECT result FROM outbox WHERE kind IN ('cash_movement', 'cash_session_close')").map((r) => r['result']),
          ['applied', 'applied'],
        );
        final cash = await http.get(Uri.parse('$base/admin/cash-sessions/$shift'), headers: {'Authorization': 'Bearer $session'});
        final detail = jsonDecode(cash.body) as Map<String, dynamic>;
        expect(detail['status'], 'closed', reason: '${cash.statusCode} ${cash.body}');
        expect(detail['closing_note'], 'Teste E2E');
        expect((detail['movements'] as List).single, containsPair('released_by_name', 'Gerente Centro'));
        final cashCount = (detail['counts'] as List).cast<Map<String, dynamic>>().first;
        expect(cashCount['method'], 'cash');
        expect(cashCount['counted'], 10);
        expect(cashCount['difference'], closeTo((cashCount['counted'] as num) - (cashCount['expected'] as num), 0.001));

        // Orçamento: o terminal vira de orçamento pela retaguarda; o PDV muda de modo na descida,
        // o vendedor monta, entrega a plaquinha e o orçamento chega à central.
        await admin('/admin/terminals/$terminalId/profile', {'profile': 'quote'}, token: session);
        await sync.pull(token.value);
        expect(pos.quoteMode, isTrue);
        expect(await pos.identifySeller('3'), isTrue);
        pos.scan('7890000000017');
        expect(await pos.finishQuote(cardNumber: 21), isTrue, reason: pos.notice?.message);
        final quoteCode = pos.lastQuote!.code;
        expect(printer.printed, contains(quoteCode));
        await sync.push(token.value);
        expect(database.debugSelect("SELECT result FROM outbox WHERE kind = 'quote'").single['result'], 'applied');
        final quotes = await http.get(Uri.parse('$base/admin/quotes?status=open'), headers: {'Authorization': 'Bearer $session'});
        final quote = (jsonDecode(quotes.body) as List).cast<Map<String, dynamic>>().singleWhere((row) => row['code'] == quoteCode);
        expect(quote['card_number'], 21);
        expect(quote['seller_name'], 'Operador Centro');
        await admin('/admin/terminals/$terminalId/profile', {'profile': 'cashier'}, token: session);
        await sync.pull(token.value);
        expect(pos.quoteMode, isFalse);

        // De volta ao caixa: turno novo, o orçamento aparece nos pendentes, é puxado pelo código do
        // cupom (com o vendedor dele) e vira venda na central.
        await pos.login('3', '2468');
        pos.openShift(5000);
        final pendingQuotes = await pos.pendingQuotes();
        expect(pendingQuotes!.map((q) => q['code']), contains(quoteCode));
        pos.scan(quoteCode);
        for (var i = 0; i < 50 && pos.cart.quoteCode == null; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(pos.cart.quoteCode, quoteCode, reason: pos.notice?.message);
        expect(pos.seller?.name, 'Operador Centro');
        pos.startPayment();
        pos.addPayment(Payment(method: PaymentMethod.cash, amountCents: pos.cart.totalCents));
        await pos.finish();
        await sync.push(token.value);
        final converted = await http.get(Uri.parse('$base/admin/quotes?status=converted'), headers: {'Authorization': 'Bearer $session'});
        final done = (jsonDecode(converted.body) as List).cast<Map<String, dynamic>>().singleWhere((row) => row['code'] == quoteCode);
        expect(done['sale_code'], pos.lastSale!.code);
        expect((await pos.findQuote!(quoteCode).then<Object>((v) => v, onError: (Object e) => e)), isA<ApiException>().having((e) => e.code, 'code', 'FA886'));

        // Devolução da venda do orçamento: a venda vem da central, o Operador Centro não tem a
        // permissão e o Gerente Centro libera; o valor vai em dinheiro e a sangria com o documento paga.
        final soldCode = pos.lastSale!.code;
        final forReturn = (await pos.findSaleForReturn(soldCode))!;
        expect(forReturn['late'], isFalse);
        final itemId = ((forReturn['items'] as List).first as Map<String, dynamic>)['id'] as String;
        final refund = await pos.makeReturn(
          sale: forReturn, quantities: {itemId: 1000}, reason: 'Teste E2E', destination: 'cash', code: '2', pin: '1357',
        );
        expect(refund, isNotNull, reason: pos.notice?.message);
        final document = (await pos.findReturnDocument(refund!.code))!;
        expect(await pos.withdraw(refund.totalCents, 'Devolução ${refund.code}', returnId: document['id'] as String), isFalse);
        expect(await pos.releaseWithdrawal(refund.totalCents, 'Devolução ${refund.code}', '2', '1357', returnId: document['id'] as String), isTrue);
        await sync.push(token.value);
        expect(
          database.debugSelect("SELECT result FROM outbox WHERE kind IN ('sale_return', 'cash_movement') ORDER BY sequence DESC LIMIT 2")
              .map((r) => r['result']),
          ['applied', 'applied'],
        );
        final returns = await http.get(Uri.parse('$base/admin/returns'), headers: {'Authorization': 'Bearer $session'});
        final returned = (jsonDecode(returns.body) as List).cast<Map<String, dynamic>>().singleWhere((row) => row['code'] == refund.code);
        expect(returned['paid'], isTrue);
        expect(returned['authorized_by_name'], 'Gerente Centro');

        // Troca: nova venda devolvida como crédito, e o crédito paga parte da compra seguinte.
        expect(await pos.identifySeller('3'), isTrue, reason: pos.notice?.message);
        pos.scan('7890000000017');
        pos.startPayment();
        pos.addPayment(Payment(method: PaymentMethod.cash, amountCents: pos.cart.totalCents));
        await pos.finish();
        await sync.push(token.value);
        final exchanged = (await pos.findSaleForReturn(pos.lastSale!.code))!;
        final exchangedItem = ((exchanged['items'] as List).single as Map<String, dynamic>)['id'] as String;
        final creditReturn = await pos.makeReturn(
          sale: exchanged, quantities: {exchangedItem: 1000}, reason: 'Troca E2E', destination: 'credit', code: '2', pin: '1357',
        );
        expect(creditReturn, isNotNull, reason: pos.notice?.message);
        await sync.push(token.value);
        expect(await pos.identifySeller('3'), isTrue, reason: pos.notice?.message);
        pos.scan('7890000000017');
        pos.scan('7890000000017');
        pos.startPayment();
        final credit = (await pos.findReturnCredit(creditReturn!.code))!;
        expect(credit.balanceCents, creditReturn.totalCents);
        pos.addPayment(Payment(
          method: PaymentMethod.returnCredit, amountCents: credit.balanceCents, returnId: credit.id, returnCode: credit.code,
          creditBalanceCents: credit.balanceCents,
        ));
        expect(pos.notice, isNull);
        pos.addPayment(Payment(method: PaymentMethod.cash, amountCents: pos.cart.remainingCents));
        await pos.finish();
        await sync.push(token.value);
        expect(
          database.debugSelect("SELECT result FROM outbox WHERE kind = 'sale' ORDER BY sequence DESC LIMIT 1").single['result'],
          'applied',
        );
        // Usado por inteiro: a central não acha mais saldo, e a lista mostra o uso.
        expect(await pos.findReturnCredit(creditReturn.code), isNull);
        expect(pos.notice?.reference, contains('FA872'));
        final credits = await http.get(Uri.parse('$base/admin/returns?destination=credit'), headers: {'Authorization': 'Bearer $session'});
        final creditRow = (jsonDecode(credits.body) as List).cast<Map<String, dynamic>>().singleWhere((row) => row['code'] == creditReturn.code);
        expect(num.parse('${creditRow['credit_used']}') * 100, creditReturn.totalCents);

        // Autenticação: cada entrada e liberação subiu e foi aceita; a retaguarda lista as do caixa.
        await sync.push(token.value);
        final authResults = database.debugSelect("SELECT result FROM outbox WHERE kind = 'auth_event'").map((r) => r['result']).toSet();
        expect(authResults, {'applied'});
        final entries = await http.get(Uri.parse('$base/admin/pdv-auth-events'), headers: {'Authorization': 'Bearer $session'});
        final authListed = (jsonDecode(entries.body) as List).cast<Map<String, dynamic>>();
        expect(authListed.where((row) => row['purpose'] == 'login' && row['user_name'] == 'Operador Centro'), isNotEmpty);
        expect(authListed.where((row) => row['purpose'] == 'approval' && row['user_name'] == 'Gerente Centro'), isNotEmpty);

        // Rosto: o Gerente Centro autoriza o cadastro do Operador Centro (código de teste, não é rosto
        // de ninguém); sobe, aparece em Usuários, é apagado na retaguarda e sai do PDV na descida.
        final enroller = (await pos.faceEnroller('2', '1357'))!;
        final operatorUser = database.userByCode(3)!;
        pos.enrollFace(
          person: operatorUser, enroller: enroller, template: [for (var i = 0; i < 128; i += 1) i.isEven ? 0.088 : -0.088],
          model: 'sface-2021dec-int8', termVersion: 'biometria-v1', consentedAt: DateTime.now(),
        );
        expect(database.userByCode(3)!.hasFace, isTrue);
        await sync.push(token.value);
        expect(database.debugSelect("SELECT result FROM outbox WHERE kind = 'face_enrollment'").single['result'], 'applied');
        final users = (jsonDecode((await http.get(Uri.parse('$base/admin/users'), headers: {'Authorization': 'Bearer $session'})).body) as List)
            .cast<Map<String, dynamic>>();
        final operatorRow = users.singleWhere((row) => '${row['code']}' == '3');
        expect(operatorRow['face_enrolled_by_name'], 'Gerente Centro');
        await admin('/admin/users/${operatorRow['id']}/revoke-face', {}, token: session);
        await sync.pull(token.value);
        expect(database.userByCode(3)!.hasFace, isFalse);
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
