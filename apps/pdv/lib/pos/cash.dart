import '../local/local_database.dart';
import 'pos_auth.dart';

/// Formas que o operador conta no fechamento. Convênio não passa pelo caixa.
const countedMethods = {
  'cash': 'Dinheiro',
  'credit_card': 'Cartão de crédito',
  'debit_card': 'Cartão de débito',
  'pix': 'PIX',
};

/// Limite de sangria da pessoa em centavos: vazio é sem teto (administrador); sem perfil com limite, zero.
int? withdrawalLimitCents(LocalUser user) {
  if (user.isAdmin) return null;
  if (!user.limits.containsKey('cash_withdrawal')) return 0;
  final value = user.limits['cash_withdrawal'];
  return value == null ? null : (value * 100).round();
}

/// A sangria cabe no limite do operador? Se não, precisa de quem libere.
bool withdrawalNeedsRelease(LocalUser operator, int amountCents) {
  final limit = withdrawalLimitCents(operator);
  return limit != null && amountCents > limit;
}

/// Quem libera é outra pessoa, com limite de sangria que cubra o valor (o supervisor; acima do limite
/// dele, o gerente).
void checkWithdrawalReleaser({required LocalUser operator, required LocalUser releaser, required int amountCents}) {
  if (releaser.id == operator.id) throw const PosException('FA992');
  final limit = withdrawalLimitCents(releaser);
  if (limit != null && amountCents > limit) throw const PosException('FA992');
}

/// Limite de venda no crediário da pessoa em centavos: vazio é sem teto (administrador); sem perfil
/// com limite, zero.
int? creditSaleLimitCents(LocalUser user) {
  if (user.isAdmin) return null;
  if (!user.limits.containsKey('credit_sale')) return 0;
  final value = user.limits['credit_sale'];
  return value == null ? null : (value * 100).round();
}
