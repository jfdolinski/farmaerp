/// Contas do crediário, iguais às do banco (app.credit_schedule, app.credit_position e
/// app.credit_allocate): os dois são conferidos pelos mesmos casos (packages/credit-cases/cases.json).
/// Valores em centavos; percentuais em centésimos (2% = 200); datas como 'AAAA-MM-DD'.
library;

/// Arredonda numerador/denominador (positivos) para o inteiro mais próximo, metade para cima.
int _roundDiv(int numerator, int denominator) => (2 * numerator + denominator) ~/ (2 * denominator);

int _hundredths(Object? value) => ((value as num? ?? 0) * 100).round();
int _cents(Object? value) => ((value as num? ?? 0) * 100).round();

DateTime _day(String text) {
  final parts = text.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}

String dayText(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

int _daysBetween(String from, String to) => _day(to).difference(_day(from)).inDays;

DateTime _addMonths(DateTime day, int months) {
  final total = day.year * 12 + (day.month - 1) + months;
  return DateTime.utc(total ~/ 12, total % 12 + 1, day.day);
}

/// Forma de vencimento da conta (a própria ou a da filial).
class CreditTerms {
  const CreditTerms({required this.dueMode, required this.closingDay, required this.dueDay, required this.intervalDays});

  factory CreditTerms.fromJson(Map<String, dynamic> json) => CreditTerms(
    dueMode: json['due_mode'] as String? ?? 'closing',
    closingDay: (json['closing_day'] as num?)?.toInt() ?? 25,
    dueDay: (json['due_day'] as num?)?.toInt() ?? 10,
    intervalDays: (json['interval_days'] as num?)?.toInt() ?? 30,
  );

  final String dueMode;
  final int closingDay;
  final int dueDay;
  final int intervalDays;
}

/// Multa e juros da filial da conta.
class CreditPolicy {
  const CreditPolicy({
    required this.lateFeeHundredths,
    required this.monthlyInterestHundredths,
    this.maxInstallments = 3,
    this.blockAfterDays = 30,
  });

  factory CreditPolicy.fromJson(Map<String, dynamic> json) => CreditPolicy(
    lateFeeHundredths: _hundredths(json['late_fee_percent']),
    monthlyInterestHundredths: _hundredths(json['monthly_interest_percent']),
    maxInstallments: (json['max_installments'] as num?)?.toInt() ?? 3,
    blockAfterDays: (json['block_after_days'] as num?)?.toInt() ?? 30,
  );

  final int lateFeeHundredths;
  final int monthlyInterestHundredths;
  final int maxInstallments;
  final int blockAfterDays;
}

class ScheduledInstallment {
  const ScheduledInstallment({required this.number, required this.dueDate, required this.amountCents});

  final int number;
  final String dueDate;
  final int amountCents;

  Map<String, Object> toJson() => {'number': number, 'due_date': dueDate, 'amount': amountCents / 100};
}

/// Parcelas de uma compra. Centavo que sobra da divisão fica na primeira.
List<ScheduledInstallment> creditSchedule(CreditTerms terms, String soldOn, int amountCents, int count) {
  final sold = _day(soldOn);
  final base = amountCents ~/ count;
  DateTime? firstDue;
  if (terms.dueMode == 'closing') {
    var close = DateTime.utc(sold.year, sold.month, terms.closingDay);
    if (sold.day > terms.closingDay) close = _addMonths(close, 1);
    firstDue = DateTime.utc(close.year, close.month, terms.dueDay);
    if (terms.dueDay <= terms.closingDay) firstDue = _addMonths(firstDue, 1);
  }
  return [
    for (var n = 1; n <= count; n += 1)
      ScheduledInstallment(
        number: n,
        dueDate: dayText(
          terms.dueMode == 'closing' ? _addMonths(firstDue!, n - 1) : sold.add(Duration(days: terms.intervalDays * n)),
        ),
        amountCents: base + (n == 1 ? amountCents - base * count : 0),
      ),
  ];
}

/// Situação de uma parcela em aberto, como a central manda (app.credit_states).
class InstallmentState {
  const InstallmentState({
    required this.id,
    required this.dueDate,
    required this.amountCents,
    required this.principalOpenCents,
    required this.feeBaseCents,
    required this.feePaidCents,
    required this.interestOpenCents,
    required this.accruedUntil,
    this.number,
  });

  factory InstallmentState.fromJson(Map<String, dynamic> json) => InstallmentState(
    id: '${json['id']}',
    number: (json['number'] as num?)?.toInt(),
    dueDate: json['due_date'] as String,
    amountCents: _cents(json['amount']),
    principalOpenCents: _cents(json['principal_open']),
    feeBaseCents: _cents(json['fee_base']),
    feePaidCents: _cents(json['fee_paid']),
    interestOpenCents: _cents(json['interest_open']),
    accruedUntil: json['accrued_until'] as String? ?? json['due_date'] as String,
  );

  final String id;
  final int? number;
  final String dueDate;
  final int amountCents;
  final int principalOpenCents;
  final int feeBaseCents;
  final int feePaidCents;
  final int interestOpenCents;
  final String accruedUntil;

  InstallmentState copyWith({int? principalOpenCents, int? feeBaseCents, int? feePaidCents, int? interestOpenCents, String? accruedUntil}) =>
      InstallmentState(
        id: id,
        number: number,
        dueDate: dueDate,
        amountCents: amountCents,
        principalOpenCents: principalOpenCents ?? this.principalOpenCents,
        feeBaseCents: feeBaseCents ?? this.feeBaseCents,
        feePaidCents: feePaidCents ?? this.feePaidCents,
        interestOpenCents: interestOpenCents ?? this.interestOpenCents,
        accruedUntil: accruedUntil ?? this.accruedUntil,
      );
}

class CreditPosition {
  const CreditPosition({required this.feeCents, required this.interestCents, required this.principalCents});

  final int feeCents;
  final int interestCents;
  final int principalCents;

  int get totalCents => feeCents + interestCents + principalCents;
}

/// Encargos de uma parcela na data: multa uma vez, sobre o que estava em aberto no vencimento; juros
/// simples por dia sobre o valor em aberto, desde o vencimento ou desde a última vez contados.
CreditPosition creditPosition(InstallmentState state, String at, CreditPolicy policy) {
  var fee = 0;
  var interest = state.interestOpenCents;
  if (_daysBetween(state.dueDate, at) > 0) {
    final total = _roundDiv(state.feeBaseCents * policy.lateFeeHundredths, 10000);
    fee = total - state.feePaidCents > 0 ? total - state.feePaidCents : 0;
    final since = _daysBetween(state.dueDate, state.accruedUntil) > 0 ? state.accruedUntil : state.dueDate;
    final days = _daysBetween(since, at);
    if (days > 0) interest += _roundDiv(state.principalOpenCents * policy.monthlyInterestHundredths * days, 300000);
  }
  return CreditPosition(feeCents: fee, interestCents: interest, principalCents: state.principalOpenCents);
}

class CreditAllocation {
  const CreditAllocation({
    required this.id,
    required this.feeCents,
    required this.interestCents,
    required this.principalCents,
    required this.interestOpenAfterCents,
  });

  final String id;
  final int feeCents;
  final int interestCents;
  final int principalCents;
  final int interestOpenAfterCents;
}

int _byDue(InstallmentState a, InstallmentState b) {
  final due = a.dueDate.compareTo(b.dueDate);
  if (due != 0) return due;
  final number = (a.number ?? 1 << 30).compareTo(b.number ?? 1 << 30);
  return number != 0 ? number : a.id.compareTo(b.id);
}

/// Como um recebimento se divide: multa e juros de cada parcela primeiro (da que vence antes para a
/// que vence depois), depois o valor das parcelas, na mesma ordem. O que sobra volta em excess.
({List<CreditAllocation> allocations, int excessCents}) creditAllocate(
  List<InstallmentState> states,
  int amountCents,
  String at,
  CreditPolicy policy,
) {
  final ordered = [...states]..sort(_byDue);
  var remaining = amountCents;
  final entries = <({String id, int fee, int interest, int interestAfter, int principalOpen})>[];
  for (final state in ordered) {
    final position = creditPosition(state, at, policy);
    final fee = remaining < position.feeCents ? remaining : position.feeCents;
    remaining -= fee;
    final interest = remaining < position.interestCents ? remaining : position.interestCents;
    remaining -= interest;
    entries.add((id: state.id, fee: fee, interest: interest, interestAfter: position.interestCents - interest, principalOpen: position.principalCents));
  }
  final result = <CreditAllocation>[];
  for (final entry in entries) {
    final principal = remaining < entry.principalOpen ? remaining : entry.principalOpen;
    remaining -= principal;
    if (entry.fee + entry.interest + principal > 0) {
      result.add(CreditAllocation(
        id: entry.id,
        feeCents: entry.fee,
        interestCents: entry.interest,
        principalCents: principal,
        interestOpenAfterCents: entry.interestAfter,
      ));
    }
  }
  return (allocations: result, excessCents: remaining);
}

/// Aplica um recebimento às parcelas, como a central fará: o que sobra em aberto depois dele.
List<InstallmentState> creditApplyPayment(List<InstallmentState> states, int amountCents, String at, CreditPolicy policy) {
  final result = creditAllocate(states, amountCents, at, policy);
  final byId = {for (final allocation in result.allocations) allocation.id: allocation};
  return [
    for (final state in states)
      if (byId[state.id] case final allocation?)
        state.copyWith(
          principalOpenCents: state.principalOpenCents - allocation.principalCents,
          feeBaseCents: _daysBetween(at, state.dueDate) >= 0 ? state.feeBaseCents - allocation.principalCents : null,
          feePaidCents: state.feePaidCents + allocation.feeCents,
          interestOpenCents: _daysBetween(state.dueDate, at) > 0 ? allocation.interestOpenAfterCents : null,
          accruedUntil: _daysBetween(state.dueDate, at) > 0 ? at : null,
        )
      else
        state,
  ].where((state) => state.principalOpenCents > 0).toList();
}
