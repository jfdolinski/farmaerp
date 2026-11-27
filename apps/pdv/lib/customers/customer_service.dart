import '../core/local_logger.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';

/// Códigos de falta de conexão: aí a busca usa só os clientes guardados no terminal.
const _offlineCodes = {'FA001', 'FA008', 'FA009'};

/// Compra do cliente nos últimos 30 dias.
class CustomerRecentSale {
  const CustomerRecentSale({required this.code, required this.soldAt, required this.branchName, required this.totalCents, required this.items});

  final String code;
  final DateTime soldAt;
  final String branchName;
  final int totalCents;
  final int items;
}

/// Produto que o cliente compra com frequência (2 ou mais compras em 180 dias).
class CustomerRecurringProduct {
  const CustomerRecurringProduct({
    required this.productId,
    required this.name,
    required this.purchases,
    required this.quantityMilli,
    required this.lastAt,
  });

  final String productId;
  final String name;
  final int purchases;
  final int quantityMilli;
  final DateTime lastAt;
}

/// Resumo das compras do cliente na rede: ticket médio de 12 meses, últimos 30 dias e recorrentes.
class CustomerHistory {
  const CustomerHistory({
    required this.sales12m,
    required this.total12mCents,
    required this.averageTicketCents,
    required this.lastPurchaseAt,
    required this.recent,
    required this.recurring,
  });

  final int sales12m;
  final int total12mCents;
  final int? averageTicketCents;
  final DateTime? lastPurchaseAt;
  final List<CustomerRecentSale> recent;
  final List<CustomerRecurringProduct> recurring;

  static int _cents(Object? value) => ((num.tryParse('${value ?? 0}') ?? 0) * 100).round();

  factory CustomerHistory.fromJson(Map<String, dynamic> json) => CustomerHistory(
    sales12m: (json['sales_12m'] as num?)?.toInt() ?? 0,
    total12mCents: _cents(json['total_12m']),
    averageTicketCents: json['average_ticket'] == null ? null : _cents(json['average_ticket']),
    lastPurchaseAt: json['last_purchase_at'] == null ? null : DateTime.parse(json['last_purchase_at'] as String),
    recent: [
      for (final sale in ((json['last_30_days'] as List?) ?? const []).cast<Map<String, dynamic>>())
        CustomerRecentSale(
          code: sale['code'] as String,
          soldAt: DateTime.parse(sale['sold_at'] as String),
          branchName: sale['branch_name'] as String,
          totalCents: _cents(sale['total']),
          items: (sale['items'] as num).toInt(),
        ),
    ],
    recurring: [
      for (final item in ((json['recurring'] as List?) ?? const []).cast<Map<String, dynamic>>())
        CustomerRecurringProduct(
          productId: item['product_id'] as String,
          name: item['name'] as String,
          purchases: (item['purchases'] as num).toInt(),
          quantityMilli: ((num.tryParse('${item['quantity']}') ?? 0) * 1000).round(),
          lastAt: DateTime.parse(item['last_at'] as String),
        ),
    ],
  );
}

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

  /// Cadastro na tela de vendas, só com internet (a central confere o CPF ou CNPJ repetido). O
  /// cliente novo fica guardado aqui, como o escolhido na busca. Pessoa jurídica vem em [company]
  /// (nome e documento saem dela). Devolve o id.
  Future<String> create({
    required String operatorId,
    String name = '',
    String document = '',
    String? phone,
    String? birthDate,
    CompanyCustomer? company,
    bool cashbackConsent = false,
    bool marketingConsent = false,
  }) async {
    final item = await api.createCustomer(accessToken: await accessToken(), data: {
      'operatorId': operatorId,
      ...?company?.toJson(),
      if (company == null) ...{
        'name': name.trim(),
        'document': document.trim(),
        'phone': (phone ?? '').trim().isEmpty ? null : phone!.trim(),
        'birthDate': birthDate,
      },
      'consents': {'cashback': cashbackConsent, 'marketing': marketingConsent},
    });
    database.saveCustomer(item);
    // Sem dados pessoais no log.
    logger?.info('Cliente cadastrado no caixa');
    return item.id;
  }

  /// Dados públicos do CNPJ para preencher o cadastro (com internet). Nada da resposta vai para o log.
  Future<CompanyCustomer> lookupCnpj({required String operatorId, required String cnpj}) async {
    final digits = cnpj.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
    return CompanyCustomer.fromLookup(digits, await api.lookupCnpj(accessToken: await accessToken(), operatorId: operatorId, cnpj: digits));
  }

  /// Histórico de compras na rede. Só com internet (erro de conexão sobe para quem chamou).
  Future<CustomerHistory> history(String id) async =>
      CustomerHistory.fromJson(await api.customerHistory(accessToken: await accessToken(), id: id));

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

/// Pessoa jurídica cadastrada no caixa, com o que a NF-e exige do destinatário: CNPJ, razão social,
/// inscrição estadual (ou ISENTO), indicador de IE e endereço completo com o código IBGE.
class CompanyCustomer {
  const CompanyCustomer({
    required this.cnpj,
    required this.legalName,
    this.tradeName,
    this.stateRegistration,
    this.ieIndicator,
    this.email,
    this.phone,
    this.postalCode,
    this.street,
    this.streetNumber,
    this.complement,
    this.district,
    this.city,
    this.cityCode,
    this.state,
  });

  /// O que a consulta do CNPJ trouxe. A inscrição e o indicador não vêm: o operador informa.
  factory CompanyCustomer.fromLookup(String cnpj, Map<String, dynamic> data) => CompanyCustomer(
    cnpj: cnpj,
    legalName: data['legalName'] as String? ?? '',
    tradeName: data['tradeName'] as String?,
    email: data['email'] as String?,
    phone: data['phone'] as String?,
    postalCode: data['postalCode'] as String?,
    street: data['street'] as String?,
    streetNumber: data['streetNumber'] as String?,
    complement: data['complement'] as String?,
    district: data['district'] as String?,
    city: data['city'] as String?,
    cityCode: data['cityCode'] as String?,
    state: data['state'] as String?,
  );

  final String cnpj;
  final String legalName;
  final String? tradeName;
  final String? stateRegistration;

  /// 1 contribuinte, 2 contribuinte isento, 9 não contribuinte; vazio segue a inscrição.
  final int? ieIndicator;
  final String? email;
  final String? phone;
  final String? postalCode;
  final String? street;
  final String? streetNumber;
  final String? complement;
  final String? district;
  final String? city;
  final String? cityCode;
  final String? state;

  Map<String, Object?> toJson() {
    String? clean(String? value) => (value ?? '').trim().isEmpty ? null : value!.trim();
    String? digits(String? value) => clean(value?.replaceAll(RegExp(r'[^0-9]'), ''));
    return {
      'personType': 'company',
      'document': cnpj.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase(),
      'name': legalName.trim(),
      'tradeName': clean(tradeName),
      'stateRegistration': clean(stateRegistration),
      'ieIndicator': ieIndicator?.toString(),
      'email': clean(email),
      'phone': digits(phone),
      'postalCode': digits(postalCode),
      'street': clean(street),
      'streetNumber': clean(streetNumber),
      'complement': clean(complement),
      'district': clean(district),
      'city': clean(city),
      'cityCode': digits(cityCode),
      'state': clean(state)?.toUpperCase(),
    };
  }
}
