import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/pos/discount_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Os mesmos casos que conferem a função do banco (app.discount_calculation): o PDV e a central
/// precisam dar o mesmo desconto, centavo a centavo.
void main() {
  final file = File('../../packages/discount-cases/cases.json');
  final cases = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final base = cases['base'] as Map<String, dynamic>;
  final products = (base['products'] as Map<String, dynamic>).cast<String, Map<String, dynamic>>();

  int milli(Object value) => ((value as num) * 1000).round();
  int cents(Object value) => ((value as num) * 100).round();

  for (final item in (cases['cases'] as List).cast<Map<String, dynamic>>()) {
    final variants = ((item['variants'] as List?) ?? const [<String, dynamic>{}]).cast<Map<String, dynamic>>();
    for (var index = 0; index < variants.length; index += 1) {
      final variant = variants[index];
      test('${item['name']}${variants.length > 1 ? ' #${index + 1}' : ''}', () {
        final rules = ((variant['rules'] ?? item['rules']) as List)
            .cast<Map<String, dynamic>>()
            .map((rule) => {...(base['rule'] as Map<String, dynamic>), ...rule})
            .toList();
        final lines = ((variant['lines'] ?? item['lines']) as List).cast<Map<String, dynamic>>().map((line) {
          return DiscountLine(
            line: line['line'] as int,
            quantityMilli: milli(line['quantity'] as Object),
            unitPriceCents: cents(line['unit_price'] as Object),
            subject: products[line['product']]!,
          );
        }).toList();
        final raw = {...(base['context'] as Map<String, dynamic>), ...((variant['context'] as Map<String, dynamic>?) ?? const {})};
        final customer = raw['customer'] as Map<String, dynamic>?;
        final context = DiscountContext(
          at: DateTime.parse(raw['at'] as String),
          today: DateTime.parse(raw['today'] as String),
          branchId: raw['branch_id'] as String?,
          paymentMethods: ((raw['payment_methods'] as List?) ?? const []).cast<String>(),
          hasCustomer: customer != null,
          customerGroupId: customer?['group_id'] as String?,
          customerBirthDate: customer?['birth_date'] as String?,
          agreementIds: ((raw['agreement_ids'] as List?) ?? const []).cast<String>(),
          coupon: raw['coupon'] as String?,
        );
        final result = calculateDiscounts(rules, lines, context);
        final expected = ((variant['expected'] ?? item['expected']) as List).cast<Map<String, dynamic>>();
        expect(
          [for (final r in result) {'line': r.line, 'total_cents': r.totalCents, 'rules': [for (final a in r.applied) a.ruleId]}],
          expected,
        );
        for (final r in result) {
          expect(r.applied.fold<int>(0, (sum, a) => sum + a.amountCents), r.totalCents);
        }
      });
    }
  }
}
