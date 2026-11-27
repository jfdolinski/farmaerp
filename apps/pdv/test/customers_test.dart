import 'dart:convert';

import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/sync/sync_service.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_test.dart' show FakeApi;

const joaoId = '019a0000-0000-7000-8000-000000000032';
const mariaId = '019a0000-0000-7000-8000-000000000033';

// CPFs de exemplo com dígitos válidos, usados em documentação: não são de pessoas reais.
Map<String, dynamic> joao({String phone = '11999990000'}) => {
  'code': 7,
  'person_type': 'individual',
  'name': 'João Conceição',
  'trade_name': null,
  'document': '11144477735',
  'phone': phone,
  'city': 'São Paulo',
  'state': 'SP',
};
Map<String, dynamic> maria() => {
  'code': 8,
  'person_type': 'company',
  'name': 'Maria Drogarias Ltda',
  'trade_name': 'Drogaria da Maria',
  'document': '11222333000181',
  'city': 'Campinas',
  'state': 'SP',
};

void main() {
  late FakeApi api;
  late LocalDatabase database;
  late CustomerService customers;

  setUp(() {
    api = FakeApi();
    database = LocalDatabase.inMemory();
    customers = CustomerService(api: api, database: database, accessToken: () async => 'token-x');
  });
  tearDown(() => database.close());

  group('clientes no banco local', () {
    test('guarda o cliente escolhido e acha sem internet por nome, código ou documento', () {
      database.saveCustomer(PullItem(type: 'customer', id: joaoId, data: joao()));
      database.saveCustomer(PullItem(type: 'customer', id: mariaId, data: maria()));
      expect(database.schemaVersion, 20);
      expect(database.customerById(joaoId), containsPair('document', '11144477735'));
      expect(database.customerById(joaoId)?.containsKey('search_text'), isFalse);

      List<String> ids(String query) => database.searchLocalCustomers(query).map((c) => c.id).toList();
      expect(ids('joao concei'), [joaoId]);
      expect(ids('DROGARIA'), [mariaId]);
      expect(ids('7'), [joaoId]);
      expect(ids('111.444.777-35'), [joaoId]);
      expect(ids('11.222.333/0001-81'), [mariaId]);
      expect(ids('50%'), isEmpty);
      expect(ids('nome_inexistente'), isEmpty);
      final found = database.searchLocalCustomers('joão').single;
      expect(found.documentMasked, '111.***.***-35');
      expect(database.searchLocalCustomers('maria').single.documentMasked, '11.222.***/****-81');
    });

    test('a descida atualiza e retira o cliente guardado', () async {
      database.saveCustomer(PullItem(type: 'customer', id: joaoId, data: joao()));
      final sync = SyncService(api: api, database: database);
      api.pullResponses.add(PullPage(format: 1, until: '9', items: [PullItem(type: 'customer', id: joaoId, data: joao(phone: '11988880000'))]));
      await sync.pull('t');
      expect(database.customerById(joaoId)?['phone'], '11988880000');
      api.pullResponses.add(const PullPage(format: 1, until: '10', items: [PullItem(type: 'customer', id: joaoId)]));
      await sync.pull('t');
      expect(database.customerById(joaoId), isNull);
    });
  });

  group('busca e escolha', () {
    test('com internet usa a central; sem internet, os clientes guardados', () async {
      api.searchResults.add(CustomerSummary.fromJson({
        'id': mariaId, 'code': 8, 'person_type': 'company', 'name': 'Maria Drogarias Ltda',
        'document_masked': '11.222.***/****-81',
      }));
      var result = await customers.search('maria');
      expect([result.online, result.customers.single.id], [true, mariaId]);
      expect(api.searchQueries, ['maria']);

      database.saveCustomer(PullItem(type: 'customer', id: joaoId, data: joao()));
      api.customerFailure = const ApiException('FA001');
      result = await customers.search('joão');
      expect([result.online, result.customers.single.id], [false, joaoId]);

      // Erro que não é de conexão chega a quem chamou (por exemplo, busca curta demais).
      api.customerFailure = const ApiException('FA961');
      await expectLater(customers.search('ab'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA961')));
    });

    test('o escolhido fica guardado; sem internet vale a cópia; excluído sai', () async {
      api.customerData[joaoId] = joao();
      expect((await customers.select(joaoId))['document'], '11144477735');
      expect(database.customerById(joaoId), isNotNull);

      api.customerFailure = const ApiException('FA001');
      expect((await customers.select(joaoId))['name'], 'João Conceição');
      await expectLater(customers.select(mariaId), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA001')));

      api.customerFailure = null;
      api.customerData[joaoId] = null;
      await expectLater(customers.select(joaoId), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA006')));
      expect(database.customerById(joaoId), isNull);
    });
  });

  group('cadastro no caixa', () {
    test('vai para a central com o operador e os consentimentos; o cliente fica guardado', () async {
      final id = await customers.create(
        operatorId: 'op-1', name: ' Ana Fictícia ', document: '11144477735', phone: ' ', birthDate: '1990-05-20',
        cashbackConsent: true,
      );
      expect(api.createdCustomers.single, {
        'operatorId': 'op-1', 'name': 'Ana Fictícia', 'document': '11144477735', 'phone': null, 'birthDate': '1990-05-20',
        'consents': {'cashback': true, 'marketing': false},
      });
      expect(database.customerById(id)?['name'], 'Ana Fictícia');
      api.createFailure = const ApiException('FA901');
      await expectLater(customers.create(operatorId: 'op-1', name: 'Outra', document: '11144477735'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA901')));
    });
  });

  group('histórico', () {
    test('ticket médio, últimos 30 dias e recorrentes, em centavos e milésimos', () async {
      api.customerHistories[joaoId] = {
        'sales_12m': 3, 'total_12m': '150.50', 'average_ticket': '50.17', 'last_purchase_at': '2026-11-20T15:00:00Z',
        'last_30_days': [
          {'sale_id': 's1', 'code': '1-000010', 'sold_at': '2026-11-20T15:00:00Z', 'branch_name': 'Loja Centro', 'total': '70.00', 'items': 2},
        ],
        'recurring': [
          {'product_id': 'p1', 'name': 'Losartana 50 mg', 'purchases': 3, 'quantity': '4.500', 'last_at': '2026-11-20T15:00:00Z'},
        ],
      };
      final history = await customers.history(joaoId);
      expect([history.sales12m, history.total12mCents, history.averageTicketCents], [3, 15050, 5017]);
      expect([history.recent.single.code, history.recent.single.totalCents, history.recent.single.items], ['1-000010', 7000, 2]);
      expect([history.recurring.single.name, history.recurring.single.purchases, history.recurring.single.quantityMilli],
          ['Losartana 50 mg', 3, 4500]);

      api.customerHistories[mariaId] = {'sales_12m': 0, 'total_12m': 0, 'average_ticket': null, 'last_purchase_at': null,
          'last_30_days': [], 'recurring': []};
      final empty = await customers.history(mariaId);
      expect([empty.averageTicketCents, empty.lastPurchaseAt, empty.recent, empty.recurring], [null, null, isEmpty, isEmpty]);

      // Só com internet.
      api.historyFailure = const ApiException('FA001');
      await expectLater(customers.history(joaoId), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA001')));
    });
  });

  group('cliente HTTP', () {
    test('a busca vai no corpo, e o detalhe pelo id', () async {
      final requests = <http.Request>[];
      final client = HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/search')) {
            return http.Response(
              jsonEncode([
                {'id': joaoId, 'code': 7, 'person_type': 'individual', 'name': 'João', 'document_masked': '111.***.***-35'},
              ]),
              200,
            );
          }
          return http.Response(jsonEncode({'id': joaoId, 'data': joao()}), 200);
        }),
      );
      final list = await client.searchCustomers(accessToken: 'abc', query: '111.444.777-35');
      expect(list.single.documentMasked, '111.***.***-35');
      expect(requests[0].method, 'POST');
      expect(requests[0].url.toString(), isNot(contains('111')));
      expect(jsonDecode(requests[0].body), {'query': '111.444.777-35'});
      expect(requests[0].headers['Authorization'], 'Bearer abc');

      final item = await client.customer(accessToken: 'abc', id: joaoId);
      expect([requests[1].method, requests[1].url.path], ['GET', '/terminals/customers/$joaoId']);
      expect(item.data?['document'], '11144477735');
    });

    test('o cadastro vai por POST, com o CPF no corpo', () async {
      late http.Request sent;
      final client = HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'id': joaoId, 'data': joao()}), 201);
        }),
      );
      final item = await client.createCustomer(accessToken: 'abc', data: {'operatorId': 'op-1', 'name': 'João', 'document': '11144477735'});
      expect([sent.method, sent.url.path], ['POST', '/terminals/customers']);
      expect(sent.url.toString(), isNot(contains('111')));
      expect(jsonDecode(sent.body), containsPair('document', '11144477735'));
      expect([item.id, item.data?['code']], [joaoId, 7]);
    });

    test('resposta em formato inesperado vira o erro genérico', () async {
      final client = HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((_) async => http.Response('{"x":1}', 200)),
      );
      await expectLater(
        client.searchCustomers(accessToken: 'abc', query: 'joao'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA000')),
      );
    });
  });
}
