import '../core/local_logger.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';

/// Códigos de falta de conexão: aí a busca usa só os clientes guardados no terminal.
const _offlineCodes = {'FA001', 'FA008', 'FA009'};

/// Resultado da busca: [online] falso quando a lista veio só dos clientes guardados aqui.
class CustomerSearchResult {
  const CustomerSearchResult({required this.customers, required this.online});

  final List<CustomerSummary> customers;
  final bool online;
}

/// Clientes no PDV: com internet, busca na central; sem internet, entre os já guardados.
/// O cliente escolhido fica guardado e a descida o mantém atualizado.
class CustomerService {
  CustomerService({
    required this.api,
    required this.database,
    required this.accessToken,
    this.logger,
  });

  final TerminalApi api;
  final LocalDatabase database;

  /// Token válido do terminal (renovado quando preciso).
  final Future<String> Function() accessToken;
  final LocalLogger? logger;

  Future<CustomerSearchResult> search(String query) async {
    try {
      final customers = await api.searchCustomers(accessToken: await accessToken(), query: query);
      return CustomerSearchResult(customers: customers, online: true);
    } on ApiException catch (error) {
      if (!_offlineCodes.contains(error.code)) rethrow;
      return CustomerSearchResult(customers: database.searchLocalCustomers(query), online: false);
    }
  }

  /// Dados completos do cliente para a venda. Sem internet, vale a cópia guardada aqui.
  Future<Map<String, Object?>> select(String id) async {
    try {
      final item = await api.customer(accessToken: await accessToken(), id: id);
      database.saveCustomer(item);
      final saved = database.customerById(id);
      if (saved == null) throw const ApiException('FA006');
      return saved;
    } on ApiException catch (error) {
      if (!_offlineCodes.contains(error.code)) rethrow;
      final saved = database.customerById(id);
      if (saved == null) rethrow;
      return saved;
    }
  }
}
