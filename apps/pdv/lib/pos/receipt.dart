import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'cart.dart';
import 'money.dart';

/// Colunas da bobina de 80 mm em fonte normal.
const receiptWidth = 48;

/// Linha do comprovante, com destaque opcional.
class ReceiptLine {
  const ReceiptLine(this.text, {this.bold = false, this.center = false});

  final String text;
  final bool bold;
  final bool center;
}

String _cnpj(String? value) => value == null || value.length != 14
    ? (value ?? '')
    : '${value.substring(0, 2)}.${value.substring(2, 5)}.${value.substring(5, 8)}/${value.substring(8, 12)}-${value.substring(12)}';

String _twoColumns(String left, String right) {
  final space = receiptWidth - right.length;
  final cut = left.length > space - 1 ? left.substring(0, space - 1) : left;
  return cut.padRight(space) + right;
}

List<String> _wrap(String text) {
  final lines = <String>[];
  var rest = text;
  while (rest.length > receiptWidth) {
    var cut = rest.lastIndexOf(' ', receiptWidth);
    if (cut <= 0) cut = receiptWidth;
    lines.add(rest.substring(0, cut).trimRight());
    rest = rest.substring(cut).trimLeft();
  }
  lines.add(rest);
  return lines;
}

/// Comprovante não fiscal da venda. A nota fiscal fica pendente até a emissão (Etapa 8).
List<ReceiptLine> buildReceipt({
  required Map<String, dynamic>? fiscal,
  required String saleCode,
  required DateTime soldAt,
  required String operatorName,
  required Cart cart,
  required int terminalNumber,
  SaleCustomer? customer,
}) {
  final branch = (fiscal?['branch'] as Map?) ?? const {};
  final company = (fiscal?['company'] as Map?) ?? const {};
  final local = soldAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final when = '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  final address = [
    branch['street'],
    branch['street_number'],
    branch['district'],
    branch['city'],
    branch['state'],
  ].where((part) => part != null && '$part'.isNotEmpty).join(', ');

  return [
    ReceiptLine((company['trade_name'] ?? company['legal_name'] ?? '') as String, bold: true, center: true),
    ReceiptLine('${branch['name'] ?? ''} · CNPJ ${_cnpj(branch['cnpj'] as String?)}', center: true),
    if (address.isNotEmpty) for (final line in _wrap(address)) ReceiptLine(line, center: true),
    const ReceiptLine(''),
    const ReceiptLine('COMPROVANTE DE VENDA', bold: true, center: true),
    const ReceiptLine('NÃO É DOCUMENTO FISCAL', center: true),
    const ReceiptLine(''),
    ReceiptLine(_twoColumns('Venda $saleCode', when)),
    ReceiptLine('Caixa $terminalNumber · Operador: $operatorName'),
    if (customer != null)
      for (final text in _wrap('Cliente: ${customer.name}${customer.documentMasked == null ? '' : ' · ${customer.documentMasked}'}'))
        ReceiptLine(text),
    ReceiptLine('-' * receiptWidth),
    for (var index = 0; index < cart.lines.length; index += 1) ...[
      for (final text in _wrap('${index + 1} ${cart.lines[index].product.code} ${cart.lines[index].product.name}')) ReceiptLine(text),
      ReceiptLine(_twoColumns(
        '  ${formatMilli(cart.lines[index].quantityMilli)} x ${formatCents(cart.lines[index].unitPriceCents)}',
        formatCents(cart.lines[index].totalCents),
      )),
      if (cart.lines[index].discountCents > 0)
        ReceiptLine(_twoColumns('  desconto', '-${formatCents(cart.lines[index].discountCents)}')),
    ],
    ReceiptLine('-' * receiptWidth),
    if (cart.discountCents > 0) ReceiptLine(_twoColumns('Descontos', '-${formatCents(cart.discountCents)}')),
    ReceiptLine(_twoColumns('TOTAL', formatCents(cart.totalCents)), bold: true),
    for (final payment in cart.payments) ...[
      ReceiptLine(_twoColumns(
        payment.method == PaymentMethod.agreement ? 'Convênio ${payment.agreementName ?? ''}' : payment.method.label,
        formatCents(payment.amountCents),
      )),
      if (payment.agreementRegistration != null) ReceiptLine('  Matrícula ${payment.agreementRegistration}'),
    ],
    if (cart.changeCents > 0) ReceiptLine(_twoColumns('Troco', formatCents(cart.changeCents))),
    const ReceiptLine(''),
    const ReceiptLine('Nota fiscal pendente de emissão.', center: true),
    const ReceiptLine('Obrigado pela preferência!', center: true),
  ];
}

/// Para onde vai o comprovante.
abstract class ReceiptPrinter {
  /// Descrição curta para a tela (nome da impressora ou a pasta do PDF).
  String get description;

  Future<void> print(String saleCode, List<ReceiptLine> lines);
}

// Página de código 860 (português) das impressoras térmicas: acentos que a bobina sabe desenhar.
const _cp860 = {
  'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ã': 0x84, 'à': 0x85, 'Á': 0x86, 'ç': 0x87, 'ê': 0x88, 'Ê': 0x89,
  'è': 0x8A, 'Í': 0x8B, 'Ô': 0x8C, 'ì': 0x8D, 'Ã': 0x8E, 'Â': 0x8F, 'É': 0x90, 'À': 0x91, 'È': 0x92, 'ô': 0x93,
  'õ': 0x94, 'ò': 0x95, 'Ú': 0x96, 'ù': 0x97, 'Ì': 0x98, 'Õ': 0x99, 'Ü': 0x9A, 'Ù': 0x9D, 'Ó': 0x9F, 'á': 0xA0,
  'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ñ': 0xA4, 'Ñ': 0xA5, 'ª': 0xA6, 'º': 0xA7, 'Ò': 0xA9, '·': 0xFA,
};

/// Comandos ESC/POS: inicia, escolhe a página 860, escreve as linhas e corta o papel.
Uint8List encodeEscPos(List<ReceiptLine> lines) {
  final bytes = BytesBuilder();
  bytes.add([0x1B, 0x40]); // ESC @: reinicia
  bytes.add([0x1B, 0x74, 0x03]); // ESC t 3: página 860
  for (final line in lines) {
    bytes.add([0x1B, 0x61, line.center ? 1 : 0]); // ESC a: alinhamento
    bytes.add([0x1B, 0x45, line.bold ? 1 : 0]); // ESC E: negrito
    for (final char in line.text.split('')) {
      final code = char.codeUnitAt(0);
      bytes.addByte(code < 0x80 ? code : (_cp860[char] ?? 0x3F));
    }
    bytes.addByte(0x0A);
  }
  bytes.add([0x1B, 0x64, 0x04]); // avança 4 linhas
  bytes.add([0x1D, 0x56, 0x42, 0x00]); // GS V B 0: corte parcial
  return bytes.toBytes();
}

/// Salva o comprovante em PDF, para testar sem impressora ou guardar a segunda via.
class PdfReceiptPrinter implements ReceiptPrinter {
  PdfReceiptPrinter(this.directory);

  final Directory directory;

  @override
  String get description => 'PDF em ${directory.path}';

  /// Último arquivo gerado, para a tela oferecer "Abrir".
  File? lastFile;

  @override
  Future<void> print(String saleCode, List<ReceiptLine> lines) async {
    final document = pw.Document(title: 'Venda $saleCode');
    final font = pw.Font.courier();
    final bold = pw.Font.courierBold();
    document.addPage(pw.Page(
      // Bobina de 80 mm, altura conforme o conteúdo.
      pageFormat: PdfPageFormat(80 * PdfPageFormat.mm, (lines.length * 4.2 + 20) * PdfPageFormat.mm, marginAll: 4 * PdfPageFormat.mm),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            pw.Text(
              line.text,
              textAlign: line.center ? pw.TextAlign.center : pw.TextAlign.left,
              style: pw.TextStyle(font: line.bold ? bold : font, fontSize: 7.2),
            ),
        ],
      ),
    ));
    directory.createSync(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}venda-$saleCode.pdf');
    await file.writeAsBytes(await document.save(), flush: true);
    lastFile = file;
  }
}
