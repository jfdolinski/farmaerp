import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;

import '../core/error_display.dart';
import '../customers/customer_service.dart';
import '../terminal/terminal_api.dart' show ApiException;
import '../ui/caps.dart';
import '../ui/pdv_motion.dart';
import '../ui/pdv_theme.dart';
import '../ui/pdv_window.dart';
import 'cart.dart';
import 'money.dart';

/// Extrato do cliente na tela toda: os números do ano em cartões e, em tabelas, as compras dos
/// últimos 30 dias e os produtos que ele costuma repetir. Busca na central uma vez, ao abrir.
class CustomerStatement extends StatelessWidget {
  const CustomerStatement({super.key, required this.customer, required this.history});

  final SaleCustomer customer;
  final Future<CustomerHistory> history;

  static String _two(int value) => value.toString().padLeft(2, '0');
  static String date(DateTime value) {
    final local = value.toLocal();
    return '${_two(local.day)}/${_two(local.month)}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    return PdvWindow(
      key: const Key('customer-history'),
      title: 'Extrato de ${customer.name}',
      tags: [
        'Código ${customer.code}',
        if (customer.documentMasked != null) customer.documentMasked!,
        if (customer.abcCurve != null) 'Curva ${customer.abcCurve}',
      ],
      closeKey: const Key('customer-history-close'),
      // As tabelas e os cartões rolam dentro do corpo (o _Body tem a própria rolagem).
      scroll: false,
      content: FutureBuilder<CustomerHistory>(
        future: history,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            final code = error is ApiException
                ? (const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA984' : error.code)
                : 'FA000';
            final display = ErrorDisplay.fromCode(code);
            return Center(
              child: Text(
                '${display.message} ${display.action}',
                key: const Key('customer-history-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) return const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator());
          return _Body(customer: customer, history: data);
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.customer, required this.history});

  final SaleCustomer customer;
  final CustomerHistory history;

  @override
  Widget build(BuildContext context) {
    final credit = customer.credit;
    final cards = <Widget>[
      _Figure(
        key: const Key('customer-history-ticket'),
        label: 'Ticket médio (12 meses)',
        value: history.averageTicketCents == null ? 'Sem compras' : formatCents(history.averageTicketCents!),
      ),
      _Figure(label: 'Compras em 12 meses', value: '${history.sales12m}'),
      _Figure(label: 'Total em 12 meses', value: formatCents(history.total12mCents)),
      _Figure(
        label: 'Última compra',
        value: history.lastPurchaseAt == null ? 'Nenhuma' : CustomerStatement.date(history.lastPurchaseAt!),
      ),
      if (credit != null)
        _Figure(
          key: const Key('customer-history-credit'),
          label: 'Crediário',
          value: credit.blocked ? 'Bloqueado' : 'Limite ${formatCents(credit.limitCents)}',
          warning: credit.blocked,
        ),
    ];
    final recent = _Table(
      key: const Key('customer-history-recent'),
      title: 'Compras dos últimos 30 dias',
      empty: 'Nenhuma compra nos últimos 30 dias.',
      columns: const ['Data', 'Venda', 'Filial', 'Itens', 'Total'],
      numeric: const {3, 4},
      rows: [
        for (final sale in history.recent)
          [CustomerStatement.date(sale.soldAt), sale.code, sale.branchName, '${sale.items}', formatCents(sale.totalCents)],
      ],
    );
    final recurring = _Table(
      key: const Key('customer-history-recurring'),
      title: 'Produtos que o cliente repete (180 dias)',
      empty: 'Nenhum produto comprado mais de uma vez.',
      columns: const ['Produto', 'Compras', 'Quantidade', 'Última compra'],
      numeric: const {1, 2},
      rowKeys: [for (final item in history.recurring) Key('customer-history-${item.productId}')],
      rows: [
        for (final item in history.recurring)
          [item.name, '${item.purchases}', formatMilli(item.quantityMilli), CustomerStatement.date(item.lastAt)],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1100;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (var i = 0; i < cards.length; i += 1)
                    PdvAppear(delay: PdvMotion.stagger * i, child: cards[i]),
                ],
              ),
              const SizedBox(height: 24),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: recent),
                    const SizedBox(width: 16),
                    Expanded(child: recurring),
                  ],
                )
              else ...[
                recent,
                const SizedBox(height: 16),
                recurring,
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Um número do cliente, grande, com o rótulo em cima.
class _Figure extends StatelessWidget {
  const _Figure({super.key, required this.label, required this.value, this.warning = false});

  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PdvColors.surface,
        borderRadius: BorderRadius.circular(PdvShape.panel),
        border: Border.all(color: warning ? PdvColors.attention : PdvColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: PdvColors.inkSoft)),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              fontFeatures: tabularFigures,
              color: warning ? PdvColors.attention : PdvColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tabela de um bloco do extrato, com título e o aviso quando não há linhas.
class _Table extends StatelessWidget {
  const _Table({
    super.key,
    required this.title,
    required this.empty,
    required this.columns,
    required this.rows,
    this.numeric = const {},
    this.rowKeys,
  });

  final String title;
  final String empty;
  final List<String> columns;
  final List<List<String>> rows;

  /// Colunas de número: alinhadas à direita.
  final Set<int> numeric;
  final List<Key>? rowKeys;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PdvColors.surface,
        borderRadius: BorderRadius.circular(PdvShape.panel),
        border: Border.all(color: PdvColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(empty, style: const TextStyle(color: PdvColors.inkSoft)),
            )
          else
            // A tabela ocupa o cartão todo; se não couber, rola para o lado.
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                columnSpacing: 24,
                horizontalMargin: 16,
                headingRowHeight: 40,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 52,
                headingTextStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: PdvColors.inkSoft),
                columns: [
                  for (var i = 0; i < columns.length; i += 1) DataColumn(label: Text(columns[i]), numeric: numeric.contains(i)),
                ],
                rows: [
                  for (var r = 0; r < rows.length; r += 1)
                    DataRow(
                      cells: [
                        for (var c = 0; c < rows[r].length; c += 1)
                          DataCell(Text(rows[r][c], key: c == 0 && rowKeys != null ? rowKeys![r] : null)),
                      ],
                    ),
                ],
              ),
              ),
              ),
            ),
        ],
      ),
    );
  }
}
