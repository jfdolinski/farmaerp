---
name: normas-fiscais
description: Consulta as normas oficiais da NF-e e da NFC-e no Portal Nacional da NF-e (nfe.fazenda.gov.br) — Manual de Orientação ao Contribuinte (MOC) e anexos, Notas Técnicas, Esquemas XML, Informes Técnicos, relação de web services e manuais de contingência. Use antes de implementar ou revisar qualquer regra fiscal da NF-e 55 ou da NFC-e 65 (leiaute, regras de validação, eventos como cancelamento e CC-e, contingência SVC/offline/EPEC, DANFE e QR Code, inutilização, endereços da Sefaz por UF, reforma tributária IBS/CBS, CNPJ alfanumérico) e quando o usuário perguntar o que a norma diz.
---

# Normas fiscais da NF-e e da NFC-e

A fonte oficial é o Portal Nacional da NF-e. Toda regra fiscal que o FarmaERP implementa
(banco, API, motor fiscal do PDV) deve seguir a versão vigente do documento do portal, citado
pelo número e pela versão.

## Como acessar

O portal não abre por busca automática de página: ele detecta cookies com redirecionamentos
(`AspxAutoDetectCookieSupport=1`) e o WebFetch entra em laço. Use o **navegador embutido**:

1. `preview_start` (ou `navigate`) com a URL da seção.
2. `get_page_text` para ler a lista.
3. Para os links reais de cada item, rode no `javascript_tool`:
   ```js
   [...document.querySelectorAll('a')]
     .map(a => [a.textContent.trim().replace(/\s+/g, ' '), a.getAttribute('href')])
     .filter(([, h]) => h && /exibirArquivo|listaHistorico|listaConteudo/.test(h))
   ```
   Os códigos nas URLs são base64: um espaço que aparecer no `href` é um `+`. Prefira clicar no
   link a montar a URL à mão.

Base das URLs: `https://www.nfe.fazenda.gov.br/portal/`.

## Mapa do portal (NF-e e NFC-e)

| Seção | URL |
|---|---|
| Manuais (MOC 7.0 e anexos, DANFE NFC-e e QR Code, contingência, SVC) | `listaConteudo.aspx?tipoConteudo=ndIjl+iEFdE=` |
| Notas Técnicas (vigentes primeiro, com versão e data) | `listaConteudo.aspx?tipoConteudo=04BIflQt1aY=` |
| Esquemas XML (pacotes de schema PL_...) | `listaConteudo.aspx?tipoConteudo=BMPFMBoln3w=` |
| Informes Técnicos | `listaConteudo.aspx?tipoConteudo=hXzemuyNHW4=` |
| Diversos | `listaConteudo.aspx?tipoConteudo=/NJarYc9nus=` |
| Relação de Serviços Web (endereços por UF e SVC) | `webServices.aspx?tipoConteudo=OUC/YVNWZfo=` |
| Disponibilidade dos serviços | `disponibilidade.aspx?versao=0.00&tipoConteudo=P2c98tUpxrI=` |
| Ajustes SINIEF | `listaConteudo.aspx?tipoConteudo=3GhDwJ/ZeSI=` |
| Atos COTEPE | `listaConteudo.aspx?tipoConteudo=AX0vPC2u8xc=` |
| Convênios | `listaConteudo.aspx?tipoConteudo=QIcipqxg0bU=` |
| Protocolos | `listaConteudo.aspx?tipoConteudo=gPWmdzYAb0Y=` |
| Atos RFB/CGIBS (reforma tributária) | `listaConteudo.aspx?tipoConteudo=ECxaPvwFHQE=` |
| Atos Técnicos RFB/CGIBS | `listaConteudo.aspx?tipoConteudo=hXHrw4cadF8=` |
| Perguntas Frequentes | `perguntasFrequentes.aspx?tipoConteudo=3Ow1nfTBzIo=` |

O menu também lista Notas Técnicas de outros documentos (NF3e, NFCom, NFGas, NFAg, NF-e ABI)
com outros códigos: não confunda com as da NF-e. Se um código mudar, ache a seção pelo menu
"Documentos" da página.

Cada item da lista aponta para `exibirArquivo.aspx?conteudo=...` (o arquivo, quase sempre PDF ou
ZIP) e, quando há, para `listaHistorico.aspx?tipoConteudo=...` (versões anteriores). Nas Notas
Técnicas o título traz número, versão e data: "Nota Técnica 2026.008 v1.01 - Publicada em
30/10/2026".

## Ler um documento

Ler as listas e as páginas do portal é livre. **Baixar um arquivo** (PDF, ZIP de schema) só com
autorização explícita do usuário, informando nome, origem e tamanho. Guarde o arquivo baixado no
diretório temporário da sessão, numa pasta só dele, e nunca dentro do repositório (o repositório é
público e os schemas que o projeto usa já estão versionados).

## Como usar no projeto

1. **Antes de implementar** uma regra fiscal, ache o documento vigente (NT ou anexo do MOC) e
   anote número, versão e data. Se houver NT mais nova que mude o que o código faz, avise o
   usuário antes de seguir.
2. **No código e no PR**, cite a fonte em português nos comentários das regras não óbvias (ex.:
   "NT 2014.001 v1.41, regra de validação 3B") e liste as fontes na descrição do PR.
3. **Compare com o que já existe:**
   - endereços da Sefaz e da SVC: `apps/api/src/sefaz/nfce-sefaz.ts`, `apps/api/src/sefaz/nfe-sefaz.ts`,
     `apps/pdv/lib/fiscal/sefaz.dart` contra a "Relação de Serviços Web";
   - leiaute e validação: motor fiscal em `apps/pdv/lib/fiscal/` (compilado para a API em
     `packages/fiscal-js`) contra o Anexo I do MOC e as NTs;
   - regras no banco (`db/migrations`): conferência das notas, prazos, eventos.
4. **Divergência** entre o código e a norma vigente vira item na lista de pendências (memória
   "Pendências do João"), com o documento e a versão, a menos que o usuário peça a correção já.
5. **Dúvida de interpretação tributária** (CFOP, CST/CSOSN, ST, regime) não se resolve só pela
   NT: registre para o contador, como as pendências 10 a 13.
6. Os testes continuam usando só a Sefaz falsa: a norma orienta o teste, nunca uma chamada à
   Sefaz real.

## Resposta ao usuário

Em português, curta, com o documento (número, versão, data) e o link da seção do portal. Resuma a
regra com suas palavras; cite trechos só quando a redação exata importar, e curtos.
