import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;

import '../ui/caps.dart';
import '../ui/pdv_motion.dart';
import '../local/local_database.dart' show SaleProduct;
import 'money.dart';

/// Lista de produtos achados pelo nome, embaixo do campo de busca. Mostra até [visibleRows] linhas
/// (menos, se a tela for baixa) e rola sozinha para a linha escolhida com as setas não sumir.
class ProductResults extends StatefulWidget {
  const ProductResults({
    super.key,
    required this.results,
    required this.highlight,
    required this.onPick,
    required this.onInfo,
    required this.onNetwork,
    this.visibleRows = 10,
  });

  final List<SaleProduct> results;
  final int highlight;
  final ValueChanged<SaleProduct> onPick;
  final ValueChanged<SaleProduct> onInfo;
  final ValueChanged<SaleProduct> onNetwork;
  final int visibleRows;

  /// Altura de cada linha (nome e, embaixo, princípio ativo, fabricante e estoque).
  static const rowHeight = 60.0;

  @override
  State<ProductResults> createState() => _ProductResultsState();
}

class _ProductResultsState extends State<ProductResults> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(ProductResults old) {
    super.didUpdateWidget(old);
    if (!identical(old.results, widget.results)) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (old.highlight != widget.highlight) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  /// Traz a linha escolhida para dentro da área visível, rolando o mínimo.
  void _reveal() {
    if (!mounted || !_scroll.hasClients || widget.highlight < 0) return;
    final position = _scroll.position;
    final top = widget.highlight * ProductResults.rowHeight;
    final bottom = top + ProductResults.rowHeight;
    if (top < position.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > position.pixels + position.viewportDimension) {
      _scroll.jumpTo((bottom - position.viewportDimension).clamp(0, position.maxScrollExtent));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.results.length < widget.visibleRows ? widget.results.length : widget.visibleRows;
    // A lista desce de leve ao abrir.
    return PdvAppear(
      offset: const Offset(0, -6),
      duration: PdvMotion.fast,
      child: Card(
      key: const Key('product-results'),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: rows * ProductResults.rowHeight,
        child: ListView.builder(
          controller: _scroll,
          itemExtent: ProductResults.rowHeight,
          itemCount: widget.results.length,
          itemBuilder: (context, index) {
            final product = widget.results[index];
            final chosen = index == widget.highlight;
            // A cor da linha escolhida passa suave de uma linha para a outra.
            return AnimatedContainer(
              duration: PdvMotion.of(context, PdvMotion.fast),
              curve: PdvMotion.curve,
              color: chosen ? Theme.of(context).colorScheme.secondaryContainer : Colors.transparent,
              child: Material(
              type: MaterialType.transparency,
              child: ListTile(
              key: Key('result-${product.code}'),
              selected: chosen,
              selectedTileColor: Colors.transparent,
              visualDensity: VisualDensity.compact,
              title: Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  if (product.activeIngredient != null) product.activeIngredient!,
                  if (product.manufacturer != null) product.manufacturer!,
                  'Estoque ${formatMilli(product.stockMilli < 0 ? 0 : product.stockMilli)}',
                  if (product.controlledClass != null) 'Controlado',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(product.priceCents == null ? 'Sem preço' : formatCents(product.priceCents!)),
                  IconButton(
                    key: Key('info-result-${product.code}'),
                    tooltip: 'DADOS DO PRODUTO',
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => widget.onInfo(product),
                  ),
                  IconButton(
                    key: Key('network-result-${product.code}'),
                    tooltip: 'ESTOQUE NAS FILIAIS',
                    icon: const Icon(Icons.store),
                    onPressed: () => widget.onNetwork(product),
                  ),
                ],
              ),
              onTap: () => widget.onPick(product),
            ),
            ),
            );
          },
        ),
      ),
    ),
    );
  }
}
