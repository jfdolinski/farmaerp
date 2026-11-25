import 'credit_engine.dart';

/// Dia em São Paulo (UTC-3, sem horário de verão desde 2019), como a central conta os vencimentos.
String saoPauloDay(DateTime instant) => dayText(instant.toUtc().subtract(const Duration(hours: 3)));

/// Dependente que pode comprar no crediário do titular.
class CreditDependent {
  const CreditDependent({required this.id, required this.name, required this.relationship});

  final String id;
  final String name;
  final String relationship;
}

/// Situação do crediário numa data: o que está em aberto, os encargos, o disponível e o atraso.
class CreditSummary {
  const CreditSummary({
    required this.principalOpenCents,
    required this.chargesOpenCents,
    required this.availableCents,
    required this.overdueDays,
    required this.blockedByOverdue,
    required this.positions,
  });

  final int principalOpenCents;
  final int chargesOpenCents;
  final int availableCents;
  final int overdueDays;
  final bool blockedByOverdue;

  /// Cada parcela em aberto, com a multa e os juros da data.
  final List<({InstallmentState state, CreditPosition position})> positions;

  int get totalOpenCents => principalOpenCents + chargesOpenCents;
}

/// Crediário do cliente como a central mandou (pdv_customer_data.credit).
class CreditAccount {
  const CreditAccount({
    required this.accountId,
    required this.blocked,
    required this.limitCents,
    required this.terms,
    required this.policy,
    required this.installments,
    required this.dependents,
  });

  static CreditAccount? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, dynamic>();
    return CreditAccount(
      accountId: '${json['account_id']}',
      blocked: json['status'] == 'blocked',
      limitCents: (((json['credit_limit'] as num?) ?? 0) * 100).round(),
      terms: CreditTerms.fromJson((json['terms'] as Map? ?? const {}).cast<String, dynamic>()),
      policy: CreditPolicy.fromJson((json['policy'] as Map? ?? const {}).cast<String, dynamic>()),
      installments: [
        for (final item in (json['installments'] as List? ?? const []).cast<Map<String, dynamic>>()) InstallmentState.fromJson(item),
      ],
      dependents: [
        for (final item in (json['dependents'] as List? ?? const []).cast<Map<String, dynamic>>())
          CreditDependent(id: '${item['id']}', name: '${item['name']}', relationship: '${item['relationship']}'),
      ],
    );
  }

  final String accountId;
  final bool blocked;
  final int limitCents;
  final CreditTerms terms;
  final CreditPolicy policy;
  final List<InstallmentState> installments;
  final List<CreditDependent> dependents;

  /// Acrescenta o que este terminal fez e a central ainda não devolveu, na ordem em que aconteceu:
  /// compras viram parcelas novas; recebimentos e devoluções abatem como a central abaterá.
  CreditAccount withPending(List<Map<String, dynamic>> events) {
    var states = [...installments];
    final ordered = [...events]..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
    for (final event in ordered) {
      final day = saoPauloDay(DateTime.parse('${event['at']}'));
      if (event['kind'] == 'sale') {
        for (final item in (event['installments'] as List? ?? const []).cast<Map<String, dynamic>>()) {
          final cents = ((item['amount'] as num) * 100).round();
          final due = '${item['due_date']}';
          states.add(InstallmentState(
            id: '${event['id']}-${item['number']}',
            number: (item['number'] as num).toInt(),
            dueDate: due,
            amountCents: cents,
            principalOpenCents: cents,
            feeBaseCents: cents,
            feePaidCents: 0,
            interestOpenCents: 0,
            accruedUntil: due,
          ));
        }
      } else {
        states = creditApplyPayment(states, ((event['amount'] as num) * 100).round(), day, policy);
      }
    }
    return CreditAccount(
      accountId: accountId,
      blocked: blocked,
      limitCents: limitCents,
      terms: terms,
      policy: policy,
      installments: states,
      dependents: dependents,
    );
  }

  CreditSummary summary(String today) {
    var principal = 0;
    var charges = 0;
    String? oldest;
    final positions = <({InstallmentState state, CreditPosition position})>[];
    final ordered = [...installments]..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    for (final state in ordered) {
      final position = creditPosition(state, today, policy);
      positions.add((state: state, position: position));
      principal += position.principalCents;
      charges += position.feeCents + position.interestCents;
      if (state.dueDate.compareTo(today) < 0 && (oldest == null || state.dueDate.compareTo(oldest) < 0)) oldest = state.dueDate;
    }
    final days = oldest == null ? 0 : DateTime.parse(today).difference(DateTime.parse(oldest)).inDays;
    return CreditSummary(
      principalOpenCents: principal,
      chargesOpenCents: charges,
      availableCents: limitCents - principal > 0 ? limitCents - principal : 0,
      overdueDays: days,
      blockedByOverdue: days > policy.blockAfterDays,
      positions: positions,
    );
  }
}
