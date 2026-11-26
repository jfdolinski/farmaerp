import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../local/local_database.dart' show LocalNfce;
import 'cart.dart';
import 'credit_engine.dart';
import 'money.dart';

/// Colunas da bobina de 80 mm em fonte normal.
const receiptWidth = 48;

/// Linha do comprovante, com destaque opcional. [barcode] imprime o texto como código de barras
/// (Code 128), centralizado e com o texto embaixo.
class ReceiptLine {
  const ReceiptLine(this.text, {this.bold = false, this.center = false}) : barcode = false, qr = false;
  const ReceiptLine.barcode(this.text) : bold = false, center = true, barcode = true, qr = false;

  /// QR Code (o da consulta da NFC-e).
  const ReceiptLine.qr(this.text) : bold = false, center = true, barcode = false, qr = true;

  final String text;
  final bool bold;
  final bool center;
  final bool barcode;
  final bool qr;
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
  int cashbackEarnedCents = 0,
  int cashbackWaitingDays = 0,
  LocalNfce? nfce,
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
    if (nfce != null && nfce.printable) ...[
      const ReceiptLine('DANFE NFC-e', bold: true, center: true),
      for (final line in _wrap('Documento Auxiliar da Nota Fiscal de Consumidor Eletrônica')) ReceiptLine(line, center: true),
    ] else ...[
      const ReceiptLine('COMPROVANTE DE VENDA', bold: true, center: true),
      const ReceiptLine('NÃO É DOCUMENTO FISCAL', center: true),
    ],
    const ReceiptLine(''),
    ReceiptLine(_twoColumns('Venda $saleCode', when)),
    ReceiptLine('Caixa $terminalNumber · Operador: $operatorName'),
    if (cart.seller != null && cart.seller!.name != operatorName) ReceiptLine('Vendedor: ${cart.seller!.name}'),
    if (cart.quoteCode != null) ReceiptLine('Orçamento ${cart.quoteCode}'),
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
      for (final applied in cart.lines[index].autoApplied)
        ReceiptLine(_twoColumns('  ${_cut(applied.name, receiptWidth - 14)}', '-${formatCents(applied.amountCents)}')),
      if (cart.lines[index].manualDiscountCents > 0)
        ReceiptLine(_twoColumns('  desconto', '-${formatCents(cart.lines[index].manualDiscountCents)}')),
      // Controlado: lote e receita. O documento do comprador não sai no papel.
      if (cart.lines[index].controlled case final controlled?) ...[
        for (final text in _wrap(controlled.isPending
            ? '  Controlado: dados da receita pendentes'
            : '  Lote ${controlled.batch!.number} · ${controlled.form!.type.label}'
              '${controlled.form!.number.trim().isEmpty ? '' : ' nº ${controlled.form!.number.trim()}'}'))
          ReceiptLine(text),
        ReceiptLine('  Farmacêutico: ${controlled.pharmacistName}'),
      ],
    ],
    ReceiptLine('-' * receiptWidth),
    if (cart.discountCents > 0) ReceiptLine(_twoColumns('Descontos', '-${formatCents(cart.discountCents)}')),
    ReceiptLine(_twoColumns('TOTAL', formatCents(cart.totalCents)), bold: true),
    for (final payment in cart.payments) ...[
      ReceiptLine(_twoColumns(
        switch (payment.method) {
          PaymentMethod.agreement => 'Convênio ${payment.agreementName ?? ''}',
          PaymentMethod.returnCredit => 'Crédito ${payment.returnCode ?? ''}',
          PaymentMethod.storeCredit => 'Crediário ${payment.installments?.length ?? 1}x',
          _ => payment.method.label,
        },
        formatCents(payment.amountCents),
      )),
      if (payment.agreementRegistration != null) ReceiptLine('  Matrícula ${payment.agreementRegistration}'),
      for (final installment in payment.installments ?? const <ScheduledInstallment>[])
        ReceiptLine(_twoColumns(
          '  ${installment.number}/${payment.installments!.length} vence ${_brDay(installment.dueDate)}',
          formatCents(installment.amountCents),
        )),
      if (payment.dependentName != null) ReceiptLine('  Comprado por ${payment.dependentName}'),
      if (payment.creditRelease != null) ReceiptLine('  Liberado por ${payment.creditRelease!.supervisorName}'),
    ],
    if (cart.changeCents > 0) ReceiptLine(_twoColumns('Troco', formatCents(cart.changeCents))),
    const ReceiptLine(''),
    if (cashbackEarnedCents > 0) ...[
      ReceiptLine(_twoColumns('Cashback ganho', formatCents(cashbackEarnedCents)), bold: true),
      if (cashbackWaitingDays > 0) ReceiptLine('  Pode ser usado daqui a $cashbackWaitingDays dias.'),
    ],
    if (cart.payments.any((payment) => payment.method == PaymentMethod.storeCredit)) ...[
      const ReceiptLine(''),
      const ReceiptLine(''),
      const ReceiptLine('______________________________', center: true),
      ReceiptLine(customer?.name ?? 'Cliente', center: true),
      const ReceiptLine('Reconheço a compra no crediário.', center: true),
      const ReceiptLine(''),
    ],
    if (nfce != null && nfce.printable) ...nfceReceiptLines(nfce, customer: customer)
    else
      const ReceiptLine('Nota fiscal pendente de emissão.', center: true),
    const ReceiptLine('Obrigado pela preferência!', center: true),
  ];
}

/// Parte fiscal do DANFE NFC-e: número, série, protocolo, consulta pela chave e o QR Code.
List<ReceiptLine> nfceReceiptLines(LocalNfce nfce, {SaleCustomer? customer}) {
  String two(int value) => value.toString().padLeft(2, '0');
  String moment(DateTime value) {
    final local = value.toLocal();
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  final key = nfce.accessKey.replaceAllMapped(RegExp(r'(\d{4})(?=\d)'), (match) => '${match[1]} ');
  return [
    if (nfce.status == 'contingency') ...[
      const ReceiptLine('EMITIDA EM CONTINGÊNCIA', bold: true, center: true),
      const ReceiptLine('Pendente de autorização', center: true),
    ],
    if (nfce.environment == 2) ...[
      const ReceiptLine('EMITIDA EM AMBIENTE DE HOMOLOGAÇÃO', bold: true, center: true),
      const ReceiptLine('SEM VALOR FISCAL', bold: true, center: true),
    ],
    ReceiptLine(customer == null ? 'CONSUMIDOR NÃO IDENTIFICADO' : 'CONSUMIDOR: ${customer.documentMasked ?? customer.name}', center: true),
    ReceiptLine('NFC-e nº ${nfce.number} Série ${nfce.series} ${moment(nfce.emittedAt)}', center: true),
    if (nfce.protocol != null && nfce.authorizedAt != null) ...[
      const ReceiptLine('Protocolo de autorização:', center: true),
      ReceiptLine('${nfce.protocol} ${moment(nfce.authorizedAt!)}', center: true),
    ],
    const ReceiptLine('Consulte pela chave de acesso em', center: true),
    for (final line in _wrap(nfce.consultUrl)) ReceiptLine(line, center: true),
    for (final line in _wrap(key)) ReceiptLine(line, center: true),
    ReceiptLine.qr(nfce.qrCode),
  ];
}

/// Cupom do orçamento: o caixa lê o código de barras. Os códigos dos produtos ficam à vista para
/// passar um a um se o caixa estiver sem internet.
List<ReceiptLine> buildQuoteReceipt({
  required Map<String, dynamic>? fiscal,
  required String quoteCode,
  required DateTime quotedAt,
  required DateTime validUntil,
  required Cart cart,
  int? cardNumber,
}) {
  final branch = (fiscal?['branch'] as Map?) ?? const {};
  final company = (fiscal?['company'] as Map?) ?? const {};
  String two(int value) => value.toString().padLeft(2, '0');
  String day(DateTime value) => '${two(value.day)}/${two(value.month)}/${value.year}';
  final local = quotedAt.toLocal();
  return [
    ReceiptLine((company['trade_name'] ?? company['legal_name'] ?? '') as String, bold: true, center: true),
    ReceiptLine('${branch['name'] ?? ''}', center: true),
    const ReceiptLine(''),
    const ReceiptLine('ORÇAMENTO', bold: true, center: true),
    const ReceiptLine('NÃO É DOCUMENTO FISCAL', center: true),
    const ReceiptLine(''),
    ReceiptLine(_twoColumns('Orçamento $quoteCode', '${day(local)} ${two(local.hour)}:${two(local.minute)}')),
    if (cardNumber != null) ReceiptLine('Plaquinha $cardNumber', bold: true),
    if (cart.seller != null) ReceiptLine('Vendedor: ${cart.seller!.name}'),
    if (cart.customer != null) for (final text in _wrap('Cliente: ${cart.customer!.name}')) ReceiptLine(text),
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
    ReceiptLine(_twoColumns('TOTAL', formatCents(cart.totalCents)), bold: true),
    const ReceiptLine(''),
    ReceiptLine('Válido até ${day(validUntil)}', center: true),
    const ReceiptLine('O preço é conferido no caixa na hora da compra.', center: true),
    ReceiptLine.barcode(quoteCode),
  ];
}

/// Destino do valor devolvido, como sai no comprovante e na tela.
const returnDestinationLabels = {
  'credit': 'Crédito para nova compra',
  'agreement': 'Abatimento na fatura do convênio',
  'cash': 'Dinheiro ao cliente',
  'store_credit': 'Abatimento no crediário',
};

/// Comprovante da devolução: o documento (com código de barras) que a sangria pede quando o valor
/// volta em dinheiro, ou que vale como crédito para nova compra.
List<ReceiptLine> buildReturnReceipt({
  required Map<String, dynamic>? fiscal,
  required String code,
  required String saleCode,
  required List<({String name, int quantityMilli, int amountCents})> items,
  required int totalCents,
  required String destination,
  required String reason,
  int cashbackRefundCents = 0,
  required String operatorName,
  String? authorizerName,
  required DateTime at,
  required int terminalNumber,
}) => [
  ..._cashHeader(fiscal, 'DEVOLUÇÃO', at, terminalNumber),
  ReceiptLine(_twoColumns('Documento $code', 'Venda $saleCode'), bold: true),
  for (final item in items) ...[
    for (final text in _wrap(item.name)) ReceiptLine(text),
    ReceiptLine(_twoColumns('  ${formatMilli(item.quantityMilli)} un', formatCents(item.amountCents))),
  ],
  ReceiptLine('-' * receiptWidth),
  ReceiptLine(_twoColumns('TOTAL DEVOLVIDO', formatCents(totalCents)), bold: true),
  if (cashbackRefundCents > 0) ...[
    ReceiptLine(_twoColumns('Volta como cashback', formatCents(cashbackRefundCents))),
    ReceiptLine(_twoColumns('Para o destino', formatCents(totalCents - cashbackRefundCents)), bold: true),
  ],
  ReceiptLine('Destino: ${returnDestinationLabels[destination] ?? destination}'),
  for (final text in _wrap(switch (destination) {
    'cash' => 'O valor sai do caixa por uma sangria de devolução com este documento.',
    'credit' => 'Apresente este documento na próxima compra nesta loja.',
    'store_credit' => 'O valor abate o que o cliente deve no crediário.',
    _ => 'O valor é abatido na próxima fatura do convênio.',
  })) ReceiptLine(text),
  for (final text in _wrap('Motivo: $reason')) ReceiptLine(text),
  ReceiptLine('Operador: $operatorName'),
  if (authorizerName != null) ReceiptLine('Liberada por: $authorizerName'),
  ReceiptLine.barcode(code),
  const ReceiptLine(''),
  const ReceiptLine('______________________________', center: true),
  const ReceiptLine('Cliente', center: true),
];

/// Cabeçalho comum dos comprovantes de caixa.
List<ReceiptLine> _cashHeader(Map<String, dynamic>? fiscal, String title, DateTime at, int terminalNumber) {
  final branch = (fiscal?['branch'] as Map?) ?? const {};
  final company = (fiscal?['company'] as Map?) ?? const {};
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return [
    ReceiptLine((company['trade_name'] ?? company['legal_name'] ?? '') as String, bold: true, center: true),
    ReceiptLine('${branch['name'] ?? ''} · Caixa $terminalNumber', center: true),
    const ReceiptLine(''),
    ReceiptLine(title, bold: true, center: true),
    ReceiptLine('${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}', center: true),
    ReceiptLine('-' * receiptWidth),
  ];
}

/// Comprovante de sangria ou suprimento, para ir junto com o envelope (com as assinaturas).
List<ReceiptLine> buildCashMovementReceipt({
  required Map<String, dynamic>? fiscal,
  required bool withdrawal,
  required int amountCents,
  required String reason,
  required String operatorName,
  String? releaserName,
  required DateTime at,
  required int terminalNumber,
}) => [
  ..._cashHeader(fiscal, withdrawal ? 'SANGRIA' : 'SUPRIMENTO', at, terminalNumber),
  ReceiptLine(_twoColumns('Valor', formatCents(amountCents)), bold: true),
  for (final text in _wrap('Motivo: $reason')) ReceiptLine(text),
  ReceiptLine('Operador: $operatorName'),
  if (releaserName != null) ReceiptLine('Liberada por: $releaserName'),
  const ReceiptLine(''),
  const ReceiptLine(''),
  const ReceiptLine('______________________________', center: true),
  const ReceiptLine('Operador', center: true),
  const ReceiptLine(''),
  const ReceiptLine('______________________________', center: true),
  ReceiptLine(withdrawal ? 'Quem recebeu o dinheiro' : 'Quem entregou o dinheiro', center: true),
];

/// Comprovante do fechamento: só o que o operador contou. O esperado e a diferença ficam na retaguarda.
List<ReceiptLine> buildClosingReceipt({
  required Map<String, dynamic>? fiscal,
  required Map<String, int> countedCents,
  required Map<String, String> labels,
  required String operatorName,
  required DateTime openedAt,
  required DateTime at,
  required int terminalNumber,
  String? note,
}) {
  final local = openedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return [
    ..._cashHeader(fiscal, 'FECHAMENTO DE CAIXA', at, terminalNumber),
    ReceiptLine('Aberto em ${two(local.day)}/${two(local.month)} ${two(local.hour)}:${two(local.minute)}'),
    ReceiptLine('Operador: $operatorName'),
    ReceiptLine('-' * receiptWidth),
    const ReceiptLine('Valores contados', bold: true),
    for (final entry in countedCents.entries) ReceiptLine(_twoColumns(labels[entry.key] ?? entry.key, formatCents(entry.value))),
    if (note != null && note.trim().isNotEmpty) ...[
      const ReceiptLine(''),
      for (final text in _wrap('Observação: ${note.trim()}')) ReceiptLine(text),
    ],
    const ReceiptLine(''),
    const ReceiptLine('A conferência é feita pela gerência.', center: true),
    const ReceiptLine(''),
    const ReceiptLine('______________________________', center: true),
    const ReceiptLine('Operador', center: true),
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
    if (line.qr) {
      final data = line.text.codeUnits.where((code) => code < 0x80).toList();
      final size = data.length + 3;
      bytes.add([0x1B, 0x61, 1]);
      bytes.add([0x1D, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0x00]); // modelo 2
      bytes.add([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x43, 5]); // tamanho do módulo
      bytes.add([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x45, 0x31]); // correção M
      bytes.add([0x1D, 0x28, 0x6B, size & 0xFF, size >> 8, 0x31, 0x50, 0x30, ...data]); // guarda o conteúdo
      bytes.add([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30]); // imprime
      bytes.addByte(0x0A);
      continue;
    }
    if (line.barcode) {
      final data = line.text.codeUnits.where((code) => code < 0x80).toList();
      bytes.add([0x1B, 0x61, 1]); // centraliza
      bytes.add([0x1D, 0x68, 80]); // GS h: altura
      bytes.add([0x1D, 0x77, 2]); // GS w: largura do módulo
      bytes.add([0x1D, 0x48, 2]); // GS H: texto embaixo
      bytes.add([0x1D, 0x6B, 73, data.length + 2, 0x7B, 0x42, ...data]); // GS k Code 128, conjunto B
      bytes.addByte(0x0A);
      continue;
    }
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
      pageFormat: PdfPageFormat(
        80 * PdfPageFormat.mm,
        (lines.length * 4.2 + lines.where((line) => line.barcode).length * 14 + lines.where((line) => line.qr).length * 34 + 20) *
            PdfPageFormat.mm,
        marginAll: 4 * PdfPageFormat.mm,
      ),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            if (line.qr)
              pw.Center(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2 * PdfPageFormat.mm),
                  child: pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: line.text, width: 30 * PdfPageFormat.mm, height: 30 * PdfPageFormat.mm),
                ),
              )
            else if (line.barcode)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2 * PdfPageFormat.mm, horizontal: 8 * PdfPageFormat.mm),
                child: pw.BarcodeWidget(
                  barcode: pw.Barcode.code128(),
                  data: line.text,
                  height: 12 * PdfPageFormat.mm,
                  textStyle: pw.TextStyle(font: font, fontSize: 7.2),
                ),
              )
            else
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

/// Corta o texto no tamanho da coluna do papel.
String _cut(String text, int max) => text.length <= max ? text : text.substring(0, max);

String _brDay(String day) => day.split('-').reversed.join('/');

/// Comprovante do recebimento do crediário: valor, quanto foi para multa e juros e o que ficou em
/// aberto (conta deste terminal; a central confirma na próxima sincronização).
List<ReceiptLine> buildCreditPaymentReceipt({
  required Map<String, dynamic>? fiscal,
  required String customerName,
  required int customerCode,
  required int amountCents,
  required String methodLabel,
  required int chargesCents,
  required int principalCents,
  required int remainingCents,
  required List<({String dueDate, int openCents})> nextDue,
  required String operatorName,
  required DateTime at,
  required int terminalNumber,
}) => [
  ..._cashHeader(fiscal, 'RECEBIMENTO DO CREDIÁRIO', at, terminalNumber),
  ReceiptLine('Cliente: $customerCode $customerName'),
  ReceiptLine(_twoColumns('Valor recebido', formatCents(amountCents)), bold: true),
  ReceiptLine(_twoColumns('Forma', methodLabel)),
  if (chargesCents > 0) ReceiptLine(_twoColumns('Multa e juros', formatCents(chargesCents))),
  ReceiptLine(_twoColumns('Parcelas', formatCents(principalCents))),
  ReceiptLine(_twoColumns('Fica em aberto', formatCents(remainingCents))),
  for (final due in nextDue) ReceiptLine(_twoColumns('  Vence ${_brDay(due.dueDate)}', formatCents(due.openCents))),
  ReceiptLine('Operador: $operatorName'),
  const ReceiptLine(''),
  const ReceiptLine('Guarde este comprovante.', center: true),
];
