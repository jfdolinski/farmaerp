import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

/// PDF da carta de correção eletrônica (CC-e) da NF-e modelo 55, em A4: o evento registrado na Sefaz
/// (procEventoNFe, com o protocolo) e os dados da nota corrigida (o XML dela, para o emitente e o
/// destinatário). Monta na retaguarda, pelo mesmo motor do DANFE.
Future<Uint8List> buildCorrectionPdf(String eventXml, String nfeXml) async {
  final event = XmlDocument.parse(eventXml);
  final sent = event.findAllElements('infEvento').first;
  final detail = sent.getElement('detEvento');
  final answer = event.findAllElements('retEvento').firstOrNull?.getElement('infEvento');
  final nfe = XmlDocument.parse(nfeXml);
  final inf = nfe.findAllElements('infNFe').firstOrNull;
  final ide = inf?.getElement('ide');
  final emit = inf?.getElement('emit');
  final dest = inf?.getElement('dest');
  final key = _t(sent, 'chNFe');
  final homologation = _t(sent, 'tpAmb') == '2';

  final regular = pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();
  final small = pw.TextStyle(font: regular, fontSize: 7);
  final value = pw.TextStyle(font: regular, fontSize: 9);
  final strong = pw.TextStyle(font: bold, fontSize: 9);

  pw.Widget cell(String label, String text, {int flex = 1, pw.TextStyle? style}) => pw.Expanded(
    flex: flex,
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [pw.Text(label.toUpperCase(), style: small), pw.Text(_safe(text), style: style ?? value)],
      ),
    ),
  );
  pw.Widget row(List<pw.Widget> cells) => pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: cells);
  pw.Widget title(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 8, bottom: 2),
    child: pw.Text(text, style: pw.TextStyle(font: bold, fontSize: 8)),
  );
  pw.Widget box(String text, {pw.TextStyle? style, double minHeight = 0}) => pw.Container(
    width: double.infinity,
    constraints: pw.BoxConstraints(minHeight: minHeight),
    padding: const pw.EdgeInsets.all(5),
    decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
    child: pw.Text(_safe(text), style: style ?? value),
  );

  final address = emit?.getElement('enderEmit');
  final recipientDocument = _t(dest, 'CNPJ').isNotEmpty ? _cnpj(_t(dest, 'CNPJ')) : _cpf(_t(dest, 'CPF'));
  final protocol = answer == null ? '' : '${_t(answer, 'nProt')} - ${_dateTime(_t(answer, 'dhRegEvento'))}';

  final document = pw.Document(title: 'Carta de correção ${_t(ide, 'nNF')}', author: 'FarmaERP');
  document.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(12 * PdfPageFormat.mm),
    footer: (context) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Folha ${context.pageNumber}/${context.pagesCount}', style: small),
    ),
    build: (context) => [
      pw.Text('CARTA DE CORREÇÃO ELETRÔNICA', style: pw.TextStyle(font: bold, fontSize: 14)),
      pw.Text('Evento 110110 da NF-e modelo 55, registrado na Sefaz', style: small),
      if (homologation)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('EMITIDA EM AMBIENTE DE HOMOLOGAÇÃO - SEM VALOR FISCAL.', style: strong),
        ),
      title('EMITENTE'),
      row([cell('Nome / razão social', _t(emit, 'xNome'), flex: 3), cell('CNPJ', _cnpj(_t(sent, 'CNPJ'))), cell('Inscrição estadual', _t(emit, 'IE'))]),
      if (address != null)
        row([
          cell('Endereço', '${_t(address, 'xLgr')}, ${_t(address, 'nro')} ${_t(address, 'xCpl')} - ${_t(address, 'xBairro')}'.trim(), flex: 3),
          cell('Município / UF', '${_t(address, 'xMun')} - ${_t(address, 'UF')}', flex: 2),
        ]),
      title('NOTA FISCAL CORRIGIDA'),
      pw.Container(
        padding: const pw.EdgeInsets.all(4),
        decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: key, height: 30, drawText: false),
            pw.SizedBox(height: 3),
            pw.Text('CHAVE DE ACESSO', style: small),
            pw.Text(_groups(key), style: strong),
          ],
        ),
      ),
      row([
        cell('Número', _number(_t(ide, 'nNF'))),
        cell('Série', _t(ide, 'serie')),
        cell('Data da emissão', _date(_t(ide, 'dhEmi'))),
        cell('Natureza da operação', _t(ide, 'natOp'), flex: 3),
      ]),
      if (dest != null) row([cell('Destinatário', _t(dest, 'xNome'), flex: 3), cell('CNPJ / CPF', recipientDocument, flex: 2)]),
      title('EVENTO'),
      row([
        cell('Sequência da carta', _t(sent, 'nSeqEvento')),
        cell('Data do evento', _dateTime(_t(sent, 'dhEvento'))),
        cell('Protocolo do registro', protocol, flex: 2, style: strong),
        cell('Situação', answer == null ? '' : '${_t(answer, 'cStat')} - ${_t(answer, 'xMotivo')}', flex: 2),
      ]),
      title('CORREÇÃO'),
      box(_t(detail, 'xCorrecao'), style: pw.TextStyle(font: regular, fontSize: 10), minHeight: 80),
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 3),
        child: pw.Text('Esta carta substitui as cartas anteriores desta nota.', style: small),
      ),
      title('CONDIÇÕES DE USO'),
      box(_t(detail, 'xCondUso'), style: small),
    ],
  ));
  return document.save();
}

String _t(XmlElement? parent, String name) => parent?.findElements(name).firstOrNull?.innerText.trim() ?? '';

/// A fonte padrão do PDF (WinAnsi) não tem todos os sinais; troca os que faltam.
String _safe(String text) => text.replaceAll('·', '-').replaceAll('–', '-').replaceAll('—', '-').replaceAll(RegExp(r'[^\u0000-ÿ€]'), '?');

String _groups(String key) => [for (var i = 0; i < key.length; i += 4) key.substring(i, (i + 4).clamp(0, key.length))].join(' ');

String _number(String n) {
  if (n.isEmpty) return '';
  final padded = n.padLeft(9, '0');
  return '${padded.substring(0, 3)}.${padded.substring(3, 6)}.${padded.substring(6)}';
}

String _cnpj(String v) => v.length == 14 ? '${v.substring(0, 2)}.${v.substring(2, 5)}.${v.substring(5, 8)}/${v.substring(8, 12)}-${v.substring(12)}' : v;

String _cpf(String v) => v.length == 11 ? '${v.substring(0, 3)}.${v.substring(3, 6)}.${v.substring(6, 9)}-${v.substring(9)}' : v;

String _date(String iso) => iso.length >= 10 ? '${iso.substring(8, 10)}/${iso.substring(5, 7)}/${iso.substring(0, 4)}' : iso;

String _dateTime(String iso) => iso.length >= 16 ? '${_date(iso)} ${iso.substring(11, 16)}' : iso;
