import '../local/local_database.dart';
import 'cart.dart';
import 'pos_auth.dart';

/// O que o desconto pedido precisa para valer.
enum DiscountNeed {
  /// O operador dá sozinho.
  none,

  /// Passa do limite do operador ou da regra do produto: precisa de um supervisor.
  release,
}

/// Limite de desconto da pessoa em centésimos de ponto: vazio é sem teto; sem perfil com limite, zero.
int? discountLimitBp(LocalUser user) {
  if (user.isAdmin) return null;
  if (!user.limits.containsKey('sale_discount')) return 0;
  final value = user.limits['sale_discount'];
  return value == null ? null : (value * 100).round();
}

/// Confere o desconto do item com as regras da central (máximo do produto e limite do operador).
/// [discountCents] maior que o item: FA980.
DiscountNeed checkDiscount({
  required CartLine line,
  required int discountCents,
  required LocalUser operator,
  required DateTime now,
}) {
  if (discountCents < 0 || discountCents > line.grossCents - line.autoDiscountCents) throw const PosException('FA980');
  if (discountCents == 0) return DiscountNeed.none;
  final percent = (discountCents * 10000 / line.grossCents).ceil();
  final ruleMax = line.product.maxDiscountAt(now);
  final aboveRule = ruleMax != null && percent > ruleMax && !operator.can('sales.discount_override');
  final limit = discountLimitBp(operator);
  final aboveLimit = limit != null && percent > limit;
  return aboveRule || aboveLimit ? DiscountNeed.release : DiscountNeed.none;
}

/// O supervisor pode liberar? Outra pessoa, com limite que cubra o desconto e, acima da regra do
/// produto, com a permissão de passar dela (dele ou do operador).
void checkSupervisor({
  required CartLine line,
  required int discountCents,
  required LocalUser operator,
  required LocalUser supervisor,
  required DateTime now,
}) {
  if (supervisor.id == operator.id) throw const PosException('FA982');
  final percent = (discountCents * 10000 / line.grossCents).ceil();
  final limit = discountLimitBp(supervisor);
  if (limit != null && percent > limit) throw const PosException('FA979');
  final ruleMax = line.product.maxDiscountAt(now);
  if (ruleMax != null && percent > ruleMax && !operator.can('sales.discount_override') && !supervisor.can('sales.discount_override')) {
    throw const PosException('FA979');
  }
}
