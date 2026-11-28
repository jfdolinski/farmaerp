import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

/// DANFE retrato em A4 da NF-e modelo 55, montado a partir do XML da nota (assinada ou com o
/// protocolo, nfeProc). Serve ao caixa (impressora padrão do Windows) e à retaguarda (PDF para baixar).
/// Sem protocolo, avisa que a nota ainda não foi autorizada; em homologação, que não tem valor fiscal.
Future<Uint8List> buildDanfeA4(String xml) async {
  final doc = XmlDocument.parse(xml);
  final inf = doc.findAllElements('infNFe').first;
  final ide = inf.getElement('ide')!;
  final emit = inf.getElement('emit')!;
  final dest = inf.getElement('dest');
  final total = inf.findAllElements('ICMSTot').first;
  final protocol = doc.findAllElements('infProt').firstOrNull;
  final key = (inf.getAttribute('Id') ?? '').replaceFirst('NFe', '');
  final homologation = _t(ide, 'tpAmb') == '2';

  final regular = pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();
  final small = pw.TextStyle(font: regular, fontSize: 6);
  final value = pw.TextStyle(font: regular, fontSize: 8);
  final strong = pw.TextStyle(font: bold, fontSize: 8);

  pw.Widget cell(String label, String? text, {int flex = 1, pw.TextStyle? style, pw.TextAlign align = pw.TextAlign.left}) => pw.Expanded(
    flex: flex,
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(label.toUpperCase(), style: small),
          pw.Text(_safe(text ?? ''), style: style ?? value, textAlign: align),
        ],
      ),
    ),
  );
  pw.Widget row(List<pw.Widget> cells) => pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: cells);
  pw.Widget title(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 4, bottom: 1),
    child: pw.Text(text, style: pw.TextStyle(font: bold, fontSize: 7)),
  );

  final address = emit.getElement('enderEmit')!;
  final header = pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        flex: 5,
        child: pw.Container(
          height: 92,
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(_safe(_t(emit, 'xNome')), style: pw.TextStyle(font: bold, fontSize: 10)),
              pw.SizedBox(height: 4),
              pw.Text(_safe('${_t(address, 'xLgr')}, ${_t(address, 'nro')} ${_t(address, 'xCpl')}'.trim()), style: value),
              pw.Text(_safe('${_t(address, 'xBairro')} - ${_t(address, 'xMun')} - ${_t(address, 'UF')}'), style: value),
              pw.Text('CEP ${_cep(_t(address, 'CEP'))}${_t(address, 'fone').isEmpty ? '' : '  Fone ${_t(address, 'fone')}'}', style: value),
            ],
          ),
        ),
      ),
      pw.Expanded(
        flex: 3,
        child: pw.Container(
          height: 92,
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
          child: pw.Column(
            children: [
              pw.Text('DANFE', style: pw.TextStyle(font: bold, fontSize: 14)),
              pw.Text('Documento Auxiliar da Nota Fiscal Eletrônica', style: small, textAlign: pw.TextAlign.center),
              pw.SizedBox(height: 4),
              pw.Text(_t(ide, 'tpNF') == '0' ? '0 - Entrada' : '1 - Saída', style: strong),
              pw.SizedBox(height: 4),
              pw.Text('Nº ${_number(_t(ide, 'nNF'))}', style: strong),
              pw.Text('Série ${_t(ide, 'serie')}', style: strong),
            ],
          ),
        ),
      ),
      pw.Expanded(
        flex: 6,
        child: pw.Container(
          height: 92,
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: key, height: 32, drawText: false),
              pw.SizedBox(height: 4),
              pw.Text('CHAVE DE ACESSO', style: small),
              pw.Text(_groups(key), style: strong),
              pw.SizedBox(height: 4),
              pw.Text('Consulta de autenticidade no portal nacional da NF-e (www.nfe.fazenda.gov.br/portal) ou no site da Sefaz autorizadora.',
                  style: small),
            ],
          ),
        ),
      ),
    ],
  );

  final protocolText = protocol == null
      ? 'NOTA AINDA NÃO AUTORIZADA'
      : '${_t(protocol, 'nProt')} - ${_dateTime(_t(protocol, 'dhRecbto'))}';
  final emitter = [
    row([
      cell('Natureza da operação', _t(ide, 'natOp'), flex: 3),
      cell('Protocolo de autorização de uso', protocolText, flex: 2, style: strong),
    ]),
    row([
      cell('Inscrição estadual', _t(emit, 'IE')),
      cell('Inscrição estadual do subst. trib.', ''),
      cell('CNPJ', _cnpj(_t(emit, 'CNPJ'))),
    ]),
  ];

  final destAddress = dest?.getElement('enderDest');
  final recipient = dest == null
      ? <pw.Widget>[]
      : [
          title('DESTINATÁRIO / REMETENTE'),
          row([
            cell('Nome / razão social', _t(dest, 'xNome'), flex: 4),
            cell('CNPJ / CPF', _t(dest, 'CNPJ').isNotEmpty ? _cnpj(_t(dest, 'CNPJ')) : _cpf(_t(dest, 'CPF')), flex: 2),
            cell('Data da emissão', _date(_t(ide, 'dhEmi'))),
          ]),
          row([
            cell('Endereço', destAddress == null ? '' : '${_t(destAddress, 'xLgr')}, ${_t(destAddress, 'nro')} ${_t(destAddress, 'xCpl')}'.trim(), flex: 3),
            cell('Bairro', destAddress == null ? '' : _t(destAddress, 'xBairro'), flex: 2),
            cell('CEP', destAddress == null ? '' : _cep(_t(destAddress, 'CEP'))),
          ]),
          row([
            cell('Município', destAddress == null ? '' : _t(destAddress, 'xMun'), flex: 3),
            cell('UF', destAddress == null ? '' : _t(destAddress, 'UF')),
            cell('Fone', destAddress == null ? '' : _t(destAddress, 'fone')),
            cell('Inscrição estadual', _t(dest, 'IE'), flex: 2),
          ]),
        ];

  final taxes = [
    title('CÁLCULO DO IMPOSTO'),
    row([
      cell('Base de cálculo do ICMS', _money(_t(total, 'vBC')), align: pw.TextAlign.right),
      cell('Valor do ICMS', _money(_t(total, 'vICMS')), align: pw.TextAlign.right),
      cell('Base de cálculo do ICMS ST', _money(_t(total, 'vBCST')), align: pw.TextAlign.right),
      cell('Valor do ICMS ST', _money(_t(total, 'vST')), align: pw.TextAlign.right),
      cell('Valor total dos produtos', _money(_t(total, 'vProd')), align: pw.TextAlign.right),
    ]),
    row([
      cell('Valor do frete', _money(_t(total, 'vFrete')), align: pw.TextAlign.right),
      cell('Valor do seguro', _money(_t(total, 'vSeg')), align: pw.TextAlign.right),
      cell('Desconto', _money(_t(total, 'vDesc')), align: pw.TextAlign.right),
      cell('Outras despesas', _money(_t(total, 'vOutro')), align: pw.TextAlign.right),
      cell('Valor do IPI', _money(_sum(_t(total, 'vIPI'), _t(total, 'vIPIDevol'))), align: pw.TextAlign.right),
      cell('Valor total da nota', _money(_t(total, 'vNF')), style: strong, align: pw.TextAlign.right),
    ]),
    title('TRANSPORTADOR / VOLUMES TRANSPORTADOS'),
    row([cell('Modalidade do frete', _freight(_t(inf.getElement('transp')!, 'modFrete')))]),
  ];

  const headers = ['Código', 'Descrição do produto', 'NCM', 'CST', 'CFOP', 'Un', 'Quant.', 'V. unit.', 'V. total', 'Desc.'];
  final rows = [
    for (final det in inf.findElements('det'))
      () {
        final prod = det.getElement('prod')!;
        final icms = det.findAllElements('ICMS').firstOrNull?.firstElementChild;
        final cst = icms == null ? '' : '${_t(icms, 'orig')}${_t(icms, 'CST').isNotEmpty ? _t(icms, 'CST') : _t(icms, 'CSOSN')}';
        return [
          _t(prod, 'cProd'),
          _safe(_t(prod, 'xProd')),
          _t(prod, 'NCM'),
          cst,
          _t(prod, 'CFOP'),
          _t(prod, 'uCom'),
          _quantity(_t(prod, 'qCom')),
          _money(_t(prod, 'vUnCom')),
          _money(_t(prod, 'vProd')),
          _money(_t(prod, 'vDesc')),
        ];
      }(),
  ];
  final products = pw.TableHelper.fromTextArray(
    headers: headers,
    data: rows,
    headerStyle: pw.TextStyle(font: bold, fontSize: 6),
    cellStyle: pw.TextStyle(font: regular, fontSize: 7),
    border: pw.TableBorder.all(width: 0.5),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 1),
    columnWidths: {
      0: const pw.FlexColumnWidth(1.4),
      1: const pw.FlexColumnWidth(5),
      2: const pw.FlexColumnWidth(1.2),
      3: const pw.FlexColumnWidth(0.7),
      4: const pw.FlexColumnWidth(0.8),
      5: const pw.FlexColumnWidth(0.6),
      6: const pw.FlexColumnWidth(1),
      7: const pw.FlexColumnWidth(1.1),
      8: const pw.FlexColumnWidth(1.1),
      9: const pw.FlexColumnWidth(0.9),
    },
    cellAlignments: {for (var i = 6; i <= 9; i += 1) i: pw.Alignment.centerRight},
    headerAlignment: pw.Alignment.centerLeft,
  );

  final notes = [
    if (homologation) 'EMITIDA EM AMBIENTE DE HOMOLOGAÇÃO - SEM VALOR FISCAL.',
    // Contingência na Sefaz Virtual: a data e o motivo vão no DANFE.
    if (_t(ide, 'tpEmis') == '6' || _t(ide, 'tpEmis') == '7')
      'EMITIDA EM CONTINGÊNCIA (${_t(ide, 'tpEmis') == '6' ? 'SVC-AN' : 'SVC-RS'}) em ${_date(_t(ide, 'dhCont'))}. Motivo: ${_t(ide, 'xJust')}.',
    if (protocol == null) 'Sem o protocolo de autorização da Sefaz: este DANFE não acompanha mercadoria.',
    for (final reference in inf.findAllElements('refNFe')) 'Nota referenciada: ${_groups(reference.innerText)}.',
    _t(inf.getElement('infAdic'), 'infCpl'),
  ].where((text) => text.trim().isNotEmpty).join('\n');

  final document = pw.Document(title: 'DANFE ${_t(ide, 'nNF')}', author: 'FarmaERP');
  document.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(10 * PdfPageFormat.mm),
    header: (context) => context.pageNumber == 1 ? pw.SizedBox() : pw.Text('DANFE ${_number(_t(ide, 'nNF'))} - chave ${_groups(key)} - continuação', style: small),
    footer: (context) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Folha ${context.pageNumber}/${context.pagesCount}', style: small),
    ),
    build: (context) => [
      header,
      ...emitter,
      ...recipient,
      ...taxes,
      title('DADOS DOS PRODUTOS / SERVIÇOS'),
      products,
      title('DADOS ADICIONAIS'),
      pw.Container(
        constraints: const pw.BoxConstraints(minHeight: 60),
        padding: const pw.EdgeInsets.all(3),
        decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
        child: pw.Text(_safe(notes), style: value),
      ),
    ],
  ));
  return document.save();
}

String _t(XmlElement? parent, String name) => parent?.findElements(name).firstOrNull?.innerText.trim() ?? '';

/// A fonte padrão do PDF (WinAnsi) não tem todos os sinais; troca os que faltam.
String _safe(String text) => text.replaceAll('·', '-').replaceAll('–', '-').replaceAll('—', '-').replaceAll(RegExp(r'[^\u0000-ÿ€]'), '?');

String _groups(String key) => [for (var i = 0; i < key.length; i += 4) key.substring(i, (i + 4).clamp(0, key.length))].join(' ');

String _number(String n) {
  final padded = n.padLeft(9, '0');
  return '${padded.substring(0, 3)}.${padded.substring(3, 6)}.${padded.substring(6)}';
}

String _money(String value) {
  if (value.isEmpty) return '0,00';
  final cents = (double.parse(value) * 100).round();
  final whole = (cents.abs() ~/ 100).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '${cents < 0 ? '-' : ''}$whole,${(cents.abs() % 100).toString().padLeft(2, '0')}';
}

String _sum(String a, String b) => ((double.tryParse(a) ?? 0) + (double.tryParse(b) ?? 0)).toStringAsFixed(2);

String _quantity(String value) => value.isEmpty ? '' : (double.parse(value)).toStringAsFixed(3).replaceAll('.', ',');

String _cnpj(String v) => v.length == 14 ? '${v.substring(0, 2)}.${v.substring(2, 5)}.${v.substring(5, 8)}/${v.substring(8, 12)}-${v.substring(12)}' : v;

String _cpf(String v) => v.length == 11 ? '${v.substring(0, 3)}.${v.substring(3, 6)}.${v.substring(6, 9)}-${v.substring(9)}' : v;

String _cep(String v) => v.length == 8 ? '${v.substring(0, 5)}-${v.substring(5)}' : v;

String _date(String iso) => iso.length >= 10 ? '${iso.substring(8, 10)}/${iso.substring(5, 7)}/${iso.substring(0, 4)}' : iso;

String _dateTime(String iso) => iso.length >= 16 ? '${_date(iso)} ${iso.substring(11, 16)}' : iso;

String _freight(String mode) => switch (mode) {
  '0' => '0 - Por conta do emitente',
  '1' => '1 - Por conta do destinatário',
  '2' => '2 - Por conta de terceiros',
  '9' => '9 - Sem frete',
  _ => mode,
};
