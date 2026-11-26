/// Endereços de consulta da NFC-e por UF: o do QR Code e o da consulta pela chave (urlChave).
///
/// CONFERIR com o portal da NFC-e de cada UF antes de emitir em produção: a Sefaz rejeita a nota
/// com endereço diferente do previsto (rejeição 395). Começamos por SP, PR, SVRS (RS e SC) e MG.
class NfceUrls {
  const NfceUrls({required this.qrCode, required this.consult});

  final String qrCode;
  final String consult;
}

const _homologation = <String, NfceUrls>{
  'SP': NfceUrls(
    qrCode: 'https://www.homologacao.nfce.fazenda.sp.gov.br/qrcode',
    consult: 'https://www.homologacao.nfce.fazenda.sp.gov.br/consulta',
  ),
  'PR': NfceUrls(qrCode: 'http://www.fazenda.pr.gov.br/nfce/qrcode', consult: 'http://www.fazenda.pr.gov.br/nfce/consulta'),
  'RS': NfceUrls(qrCode: 'https://www.sefaz.rs.gov.br/NFCE/NFCE-COM.aspx', consult: 'http://www.sefaz.rs.gov.br/nfce/consulta'),
  'SC': NfceUrls(qrCode: 'https://hom.sat.sef.sc.gov.br/nfce/consulta', consult: 'https://hom.sat.sef.sc.gov.br/nfce/consulta'),
  'MG': NfceUrls(
    qrCode: 'https://portalsped.fazenda.mg.gov.br/portalnfce/sistema/qrcode.xhtml',
    consult: 'https://hportalsped.fazenda.mg.gov.br/portalnfce',
  ),
};

const _production = <String, NfceUrls>{
  'SP': NfceUrls(qrCode: 'https://www.nfce.fazenda.sp.gov.br/qrcode', consult: 'https://www.nfce.fazenda.sp.gov.br/consulta'),
  'PR': NfceUrls(qrCode: 'http://www.fazenda.pr.gov.br/nfce/qrcode', consult: 'http://www.fazenda.pr.gov.br/nfce/consulta'),
  'RS': NfceUrls(qrCode: 'https://www.sefaz.rs.gov.br/NFCE/NFCE-COM.aspx', consult: 'http://www.sefaz.rs.gov.br/nfce/consulta'),
  'SC': NfceUrls(qrCode: 'https://sat.sef.sc.gov.br/nfce/consulta', consult: 'https://sat.sef.sc.gov.br/nfce/consulta'),
  'MG': NfceUrls(
    qrCode: 'https://portalsped.fazenda.mg.gov.br/portalnfce/sistema/qrcode.xhtml',
    consult: 'https://portalsped.fazenda.mg.gov.br/portalnfce',
  ),
};

/// Endereços da UF no ambiente (1 produção, 2 homologação). Null quando a UF ainda não é atendida.
NfceUrls? nfceUrls(String uf, int environment) => (environment == 1 ? _production : _homologation)[uf];
