import 'money.dart';

/// Desconto automático que valeu num item: a regra, o nome (para a explicação) e o valor.
class AppliedDiscount {
  const AppliedDiscount({required this.ruleId, required this.name, required this.kind, required this.amountCents});

  final String ruleId;
  final String name;
  final String kind;
  final int amountCents;
}

/// Item para o cálculo: quantidade em milésimos, preço em centavos e onde o produto está na
/// hierarquia do motor (ids de família, fabricante, categorias e grupos).
class DiscountLine {
  const DiscountLine({required this.line, required this.quantityMilli, required this.unitPriceCents, required this.subject});

  final int line;
  final int quantityMilli;
  final int unitPriceCents;
  final Map<String, Object?> subject;
}

/// O que a venda tem agora: hora, filial, formas de pagamento, cliente (grupo e nascimento),
/// convênios usados e o cupom digitado.
class DiscountContext {
  const DiscountContext({
    required this.at,
    required this.today,
    this.branchId,
    this.paymentMethods = const [],
    this.customerGroupId,
    this.customerBirthDate,
    this.hasCustomer = false,
    this.agreementIds = const [],
    this.coupon,
  });

  final DateTime at;
  final DateTime today;
  final String? branchId;
  final List<String> paymentMethods;
  final bool hasCustomer;
  final String? customerGroupId;
  final String? customerBirthDate;
  final List<String> agreementIds;
  final String? coupon;
}

/// Resultado de um item: total do desconto automático e as regras que valeram.
class LineDiscount {
  const LineDiscount({required this.line, required this.totalCents, required this.applied});

  final int line;
  final int totalCents;
  final List<AppliedDiscount> applied;
}

/// Percentual em décimos de milésimo (10,5% = 105000), para a conta ficar só em inteiros.
int? _percentE4(Object? value) {
  if (value == null) return null;
  final number = value is num ? value : num.tryParse('$value');
  return number == null ? null : (number * 10000).round();
}

/// Arredonda numerador/denominador (positivos) para o inteiro mais próximo, metade para cima.
int _roundDiv(int numerator, int denominator) => (2 * numerator + denominator) ~/ (2 * denominator);

DateTime? _instant(Object? value) => value == null ? null : DateTime.tryParse('$value');

/// O cálculo dos descontos automáticos, igual ao do banco (app.discount_calculation): os dois são
/// conferidos pelos mesmos casos (packages/discount-cases/cases.json).
List<LineDiscount> calculateDiscounts(List<Map<String, dynamic>> rules, List<DiscountLine> lines, DiscountContext context) {
  final coupon = (context.coupon ?? '').trim().toUpperCase();
  var cartCents = 0;
  for (final line in lines) {
    cartCents += lineGrossCents(line.unitPriceCents, line.quantityMilli);
  }
  final ordered = [...rules]..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));

  bool targets(Map<String, dynamic> rule, Map<String, Object?> product) {
    final target = rule['target_id'];
    String? field(String name) => product[name] as String?;
    return switch (rule['level']) {
      'product' => target == field('id'),
      'price_family' => target != null && target == field('price_family_id'),
      'manufacturer' => target != null && target == field('manufacturer_id'),
      'subcategory' => target != null && target == field('subcategory_id'),
      'category' => target != null && target == field('category_id'),
      'department' => target != null && target == field('department_id'),
      'pricing_group' => target != null && target == field('pricing_group_id'),
      'commission_group' => target != null && target == field('commission_group_id'),
      'store_default' => true,
      _ => false,
    };
  }

  bool conditions(Map<String, dynamic> rule) => switch (rule['kind']) {
    'payment_method' =>
      context.paymentMethods.isNotEmpty && context.paymentMethods.every((method) => method == rule['payment_method']),
    'customer_group' => context.hasCustomer && context.customerGroupId != null && context.customerGroupId == rule['customer_group_id'],
    'agreement' => context.agreementIds.contains(rule['agreement_id']),
    'birthday' => context.hasCustomer &&
        context.customerBirthDate != null &&
        DateTime.tryParse(context.customerBirthDate!)?.month == context.today.month,
    'cart_total' => cartCents >= ((_percentE4(rule['min_total']) ?? 0) / 100).round(),
    'coupon' => coupon.isNotEmpty && coupon == rule['coupon'],
    _ => true,
  };

  final result = <LineDiscount>[];
  for (final line in lines) {
    final gross = lineGrossCents(line.unitPriceCents, line.quantityMilli);
    final units = line.quantityMilli ~/ 1000;
    Map<String, dynamic>? best;
    var bestAmount = 0;
    final cumulative = <(Map<String, dynamic>, int)>[];
    var cumulativeSum = 0;
    for (final rule in ordered) {
      final from = _instant(rule['valid_from']);
      final to = _instant(rule['valid_to']);
      if ((from != null && from.isAfter(context.at)) || (to != null && !to.isAfter(context.at))) continue;
      final branch = rule['branch_id'];
      if (branch != null && branch != context.branchId) continue;
      if (!targets(rule, line.subject) || !conditions(rule)) continue;
      var amount = switch (rule['kind']) {
        'buy_x_pay_y' => () {
          final buy = (rule['buy_quantity'] as num).toInt();
          final pay = (rule['pay_quantity'] as num).toInt();
          return (units ~/ buy) * (buy - pay) * line.unitPriceCents;
        }(),
        'quantity' => () {
          final from = (rule['min_quantity'] as num).toInt();
          final eligible = units - (from - 1) > 0 ? units - (from - 1) : 0;
          return _roundDiv(line.unitPriceCents * eligible * (_percentE4(rule['percent']) ?? 0), 1000000);
        }(),
        _ => _roundDiv(gross * (_percentE4(rule['percent']) ?? 0), 1000000),
      };
      if (amount > gross) amount = gross;
      if (amount <= 0) continue;
      if (rule['stacking'] == 'exclusive') {
        if (amount > bestAmount) {
          best = rule;
          bestAmount = amount;
        }
      } else {
        cumulative.add((rule, amount));
        cumulativeSum += amount;
      }
    }

    AppliedDiscount applied(Map<String, dynamic> rule, int amount) => AppliedDiscount(
      ruleId: '${rule['id']}',
      name: '${rule['name']}',
      kind: '${rule['kind']}',
      amountCents: amount,
    );
    if (best != null && bestAmount > cumulativeSum) {
      result.add(LineDiscount(line: line.line, totalCents: bestAmount, applied: [applied(best, bestAmount)]));
      continue;
    }
    var remaining = gross;
    var total = 0;
    final chosen = <AppliedDiscount>[];
    for (final (rule, value) in cumulative) {
      final amount = value < remaining ? value : remaining;
      if (amount <= 0) break;
      chosen.add(applied(rule, amount));
      remaining -= amount;
      total += amount;
    }
    result.add(LineDiscount(line: line.line, totalCents: total, applied: chosen));
  }
  return result;
}
