// Motor fiscal (NF-e modelo 55 e DANFE A4) compilado para JavaScript, para a central (API) emitir com
// o mesmo código do PDV. Gerar: npm run -s generate em packages/fiscal-js (dart compile js).
// Expõe em globalThis.farmaerpFiscal:
//   buildNfe(inputJson, keyPem, certPem) -> JSON {accessKey, xml, totalCents} ou {error: {code, detail}}
//   buildDanfe(xml) -> Promise<string> (PDF em base64)
//   svcEmissionType(uf) -> 6 (SVC-AN), 7 (SVC-RS) ou null
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:farmaerp_pdv/fiscal/danfe_a4.dart';
import 'package:farmaerp_pdv/fiscal/nfce.dart';
import 'package:farmaerp_pdv/fiscal/xml_signer.dart';

NfceIssuer _issuer(Map<String, dynamic> m) => NfceIssuer(
  cnpj: m['cnpj'] as String,
  stateRegistration: m['stateRegistration'] as String,
  legalName: m['legalName'] as String,
  tradeName: (m['tradeName'] as String?) ?? m['legalName'] as String,
  street: m['street'] as String,
  number: m['number'] as String,
  complement: m['complement'] as String?,
  district: m['district'] as String,
  cityCode: m['cityCode'] as String,
  city: m['city'] as String,
  uf: m['uf'] as String,
  postalCode: m['postalCode'] as String,
  phone: m['phone'] as String?,
  taxRegime: (m['taxRegime'] as num).toInt(),
);

NfeRecipient _recipient(Map<String, dynamic> m) => NfeRecipient(
  cnpj: m['cnpj'] as String?,
  cpf: m['cpf'] as String?,
  name: m['name'] as String,
  ieIndicator: (m['ieIndicator'] as num).toInt(),
  stateRegistration: m['stateRegistration'] as String?,
  street: m['street'] as String,
  number: m['number'] as String,
  complement: m['complement'] as String?,
  district: m['district'] as String,
  cityCode: m['cityCode'] as String,
  city: m['city'] as String,
  uf: m['uf'] as String,
  postalCode: m['postalCode'] as String,
  phone: m['phone'] as String?,
  email: m['email'] as String?,
);

NfceItem _item(Map<String, dynamic> m) => NfceItem(
  code: m['code'] as String,
  gtin: m['gtin'] as String?,
  description: m['description'] as String,
  ncm: m['ncm'] as String,
  cest: m['cest'] as String?,
  unit: (m['unit'] as String?) ?? 'UN',
  quantityMilli: (m['quantityMilli'] as num).toInt(),
  unitPriceCents: (m['unitPriceCents'] as num).toInt(),
  grossCents: (m['grossCents'] as num).toInt(),
  discountCents: (m['discountCents'] as num? ?? 0).toInt(),
  freightCents: (m['freightCents'] as num? ?? 0).toInt(),
  insuranceCents: (m['insuranceCents'] as num? ?? 0).toInt(),
  otherCents: (m['otherCents'] as num? ?? 0).toInt(),
  ipiReturnedCents: (m['ipiReturnedCents'] as num? ?? 0).toInt(),
  returnPercent: m['returnPercent'] as num?,
  tax: (m['tax'] as Map).cast<String, dynamic>(),
);

String _buildNfe(String inputJson, String keyPem, String certPem) {
  try {
    final m = (jsonDecode(inputJson) as Map).cast<String, dynamic>();
    final input = NfeInput(
      issuer: _issuer((m['issuer'] as Map).cast<String, dynamic>()),
      recipient: _recipient((m['recipient'] as Map).cast<String, dynamic>()),
      items: [for (final item in m['items'] as List) _item((item as Map).cast<String, dynamic>())],
      payments: [
        for (final p in (m['payments'] as List?) ?? const [])
          NfcePayment(type: (p as Map)['type'] as String, cents: (p['cents'] as num).toInt(), description: p['description'] as String?),
      ],
      series: (m['series'] as num).toInt(),
      number: (m['number'] as num).toInt(),
      emittedAt: DateTime.parse(m['emittedAt'] as String),
      environment: (m['environment'] as num).toInt(),
      numericCode: m['numericCode'] as String,
      appVersion: m['appVersion'] as String,
      operation: m['operation'] as String,
      purpose: (m['purpose'] as num? ?? 1).toInt(),
      presence: (m['presence'] as num? ?? 1).toInt(),
      finalConsumer: m['finalConsumer'] as bool?,
      references: [for (final r in (m['references'] as List?) ?? const []) r as String],
      freightMode: (m['freightMode'] as num? ?? 9).toInt(),
      additionalInfo: m['additionalInfo'] as String?,
      ibsCbs: m['ibsCbs'] as bool? ?? false,
      emissionType: (m['emissionType'] as num? ?? 1).toInt(),
      contingencyAt: m['contingencyAt'] == null ? null : DateTime.parse(m['contingencyAt'] as String),
      contingencyReason: m['contingencyReason'] as String?,
    );
    final credential = SigningCredential.fromPem(privateKeyPem: keyPem, certificatePem: certPem);
    final nfe = buildNfe(input, credential);
    return jsonEncode({'accessKey': nfe.accessKey, 'xml': nfe.xml, 'totalCents': nfe.totalCents});
  } on FiscalException catch (error) {
    return jsonEncode({'error': {'code': error.code, 'detail': error.detail}});
  } catch (error) {
    // Dado fora do formato: o detalhe vai para o log da API, nunca para a tela.
    return jsonEncode({'error': {'code': 'FA726', 'detail': 'Entrada inválida: ${error.runtimeType}'}});
  }
}

JSPromise<JSString> _buildDanfe(String xml) =>
    buildDanfeA4(xml).then((bytes) => base64Encode(bytes).toJS).toJS;

void main() {
  final api = JSObject();
  api['buildNfe'] = ((JSString input, JSString key, JSString cert) => _buildNfe(input.toDart, key.toDart, cert.toDart).toJS).toJS;
  api['buildDanfe'] = ((JSString xml) => _buildDanfe(xml.toDart)).toJS;
  api['svcEmissionType'] = ((JSString uf) => svcEmissionType(uf.toDart)?.toJS).toJS;
  globalContext['farmaerpFiscal'] = api;
}
