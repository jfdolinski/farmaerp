import 'package:flutter/material.dart';

import '../local/local_database.dart';
import 'money.dart';
import 'pos_controller.dart';

const _statusLabels = {
  'active': 'Ativo',
  'on_order': 'Por encomenda',
  'blocked': 'Bloqueado para compra',
  'inactive': 'Inativo',
};

/// Consulta dos dados de cadastro do produto que o terminal tem (sem internet também).
Future<void> showProductInfo(BuildContext context, PosController controller, SaleProduct product) {
  final data = controller.database.productDetails(product.id);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('product-info'),
      title: Text('${product.code} · ${product.name}'),
      content: SizedBox(
        width: 520,
        child: data == null
            ? const Text('Este produto não está mais na cópia do terminal.')
            : SingleChildScrollView(child: _Details(data: data)),
      ),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Fechar'))],
    ),
  );
}

class _Details extends StatelessWidget {
  const _Details({required this.data});

  final Map<String, Object?> data;

  @override
  Widget build(BuildContext context) {
    String? text(String key) {
      final value = data[key];
      return value == null || '$value'.isEmpty ? null : '$value';
    }

    final bp = data['max_discount_bp'] as int?;
    final until = DateTime.tryParse(data['max_discount_until'] as String? ?? '')?.toLocal();
    final barcodes = (data['barcodes'] as List).cast<Map<String, Object?>>();
    final batches = (data['batches'] as List).cast<Map<String, Object?>>();
    final rows = <(String, String?)>[
      ('Código', '${data['code']}'),
      ('Princípio ativo', text('active_ingredient')),
      ('Fabricante', text('manufacturer')),
      ('Situação na loja', _statusLabels[data['status']] ?? text('status')),
      ('Preço', data['price_cents'] == null ? 'Sem preço' : formatCents(data['price_cents']! as int)),
      ('Desconto máximo', bp == null
          ? 'Sem regra'
          : '${formatCents(bp).replaceFirst('R\$ ', '')}%${until == null ? '' : ' até ${until.day.toString().padLeft(2, '0')}/${until.month.toString().padLeft(2, '0')}/${until.year}'}'),
      ('Controlado', text('controlled_class') == null ? 'Não' : 'Lista ${data['controlled_class']}'),
      ('Registro no MS', text('ms_registration')),
      ('NCM', text('ncm')),
      ('CEST', text('cest')),
      ('Fracionamento', data['fraction_milli'] == null || data['fraction_milli'] == 1000 ? 'Não' : 'Unidade de ${formatMilli(data['fraction_milli']! as int)}'),
      ('Exige lote', data['batch_required'] == true ? 'Sim' : 'Não'),
      ('Estoque na cópia local', data['stock_milli'] == null ? 'Sem saldo' : formatMilli(data['stock_milli']! as int)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          if (value != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 180, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(child: Text(value, key: Key('info-$label'))),
                ],
              ),
            ),
        if (barcodes.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Códigos de barras', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final barcode in barcodes)
            Text([
              '${barcode['code']}',
              if (barcode['primary'] == true) 'principal',
              if (barcode['fraction_milli'] != null) 'vale ${formatMilli(barcode['fraction_milli']! as int)}',
            ].join(' · ')),
        ],
        if (batches.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Lotes', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final batch in batches)
            Text('${batch['number']} · vence ${(batch['expires_on'] as String).split('-').reversed.join('/')} · '
                'saldo ${formatMilli(batch['quantity_milli']! as int)}'),
        ],
      ],
    );
  }
}
