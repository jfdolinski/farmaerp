import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/pos/credit_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Os mesmos casos que conferem as funções do banco (app.credit_*): o PDV e a central precisam dar
/// os mesmos vencimentos, encargos e abatimentos, centavo a centavo.
void main() {
  final cases = jsonDecode(File('../../packages/credit-cases/cases.json').readAsStringSync()) as Map<String, dynamic>;
  int cents(Object? value) => ((value as num) * 100).round();

  for (final item in (cases['schedule'] as List).cast<Map<String, dynamic>>()) {
    test('vencimentos: ${item['name']}', () {
      final result = creditSchedule(
        CreditTerms.fromJson(item['terms'] as Map<String, dynamic>),
        item['sold_on'] as String,
        cents(item['amount']),
        item['count'] as int,
      );
      expect(
        [for (final i in result) {'number': i.number, 'due_date': i.dueDate, 'amount': i.amountCents}],
        [
          for (final e in (item['expected'] as List).cast<Map<String, dynamic>>())
            {'number': e['number'], 'due_date': e['due_date'], 'amount': cents(e['amount'])},
        ],
      );
    });
  }

  for (final item in (cases['position'] as List).cast<Map<String, dynamic>>()) {
    test('encargos: ${item['name']}', () {
      final state = InstallmentState.fromJson({'id': 'x', ...item['state'] as Map<String, dynamic>});
      final position = creditPosition(state, item['at'] as String, CreditPolicy.fromJson(item['policy'] as Map<String, dynamic>));
      final expected = item['expected'] as Map<String, dynamic>;
      expect(
        [position.feeCents, position.interestCents, position.principalCents],
        [cents(expected['fee']), cents(expected['interest']), cents(expected['principal'])],
      );
    });
  }

  for (final item in (cases['allocate'] as List).cast<Map<String, dynamic>>()) {
    test('abatimento: ${item['name']}', () {
      final states = [for (final s in (item['states'] as List).cast<Map<String, dynamic>>()) InstallmentState.fromJson(s)];
      final result = creditAllocate(states, cents(item['amount']), item['at'] as String, CreditPolicy.fromJson(item['policy'] as Map<String, dynamic>));
      final expected = item['expected'] as Map<String, dynamic>;
      expect(
        [for (final a in result.allocations) [a.id, a.feeCents, a.interestCents, a.principalCents, a.interestOpenAfterCents]],
        [
          for (final e in (expected['allocations'] as List).cast<Map<String, dynamic>>())
            [e['id'], cents(e['fee']), cents(e['interest']), cents(e['principal']), cents(e['interest_open_after'])],
        ],
      );
      expect(result.excessCents, cents(expected['excess']));
    });
  }

  test('recebimento aplicado: o que fica em aberto, com os juros contados até a data', () {
    const policy = CreditPolicy(lateFeeHundredths: 200, monthlyInterestHundredths: 100);
    final states = [
      const InstallmentState(id: 'a', dueDate: '2026-12-10', amountCents: 5000, principalOpenCents: 5000, feeBaseCents: 5000, feePaidCents: 0, interestOpenCents: 0, accruedUntil: '2026-12-10'),
      const InstallmentState(id: 'b', dueDate: '2027-01-10', amountCents: 5000, principalOpenCents: 5000, feeBaseCents: 5000, feePaidCents: 0, interestOpenCents: 0, accruedUntil: '2027-01-10'),
    ];
    final after = creditApplyPayment(states, 120, '2027-01-09', policy);
    expect(after.first.feePaidCents, 100);
    expect(after.first.interestOpenCents, 30);
    expect(after.first.accruedUntil, '2027-01-09');
    final paid = creditApplyPayment(states, 10000, '2026-12-01', policy);
    expect(paid, isEmpty);
    final early = creditApplyPayment(states, 2000, '2026-12-01', policy);
    expect([early.first.principalOpenCents, early.first.feeBaseCents], [3000, 3000]);
  });
}
