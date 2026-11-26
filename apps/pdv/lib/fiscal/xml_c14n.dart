import 'package:xml/xml.dart';

/// Canonicalização inclusiva do XML (C14N 1.0, sem comentários), para a assinatura digital.
/// Cobre o que a NF-e usa: namespaces padrão (sem prefixo), atributos sem prefixo e texto.
String canonicalize(XmlElement element) {
  final buffer = StringBuffer();
  _render(element, buffer, renderedNamespace: '', inheritedNamespace: _inheritedNamespace(element));
  return buffer.toString();
}

/// Namespace padrão em vigor no elemento (o dele ou o do ancestral mais próximo).
String _inheritedNamespace(XmlElement element) {
  XmlNode? node = element;
  while (node is XmlElement) {
    final value = node.getAttribute('xmlns');
    if (value != null) return value;
    node = node.parent;
  }
  return '';
}

void _render(XmlElement element, StringBuffer out, {required String renderedNamespace, required String inheritedNamespace}) {
  final own = element.getAttribute('xmlns');
  final namespace = own ?? inheritedNamespace;
  out.write('<${element.name.local}');
  if (namespace != renderedNamespace) out.write(' xmlns="${_escapeAttribute(namespace)}"');
  final attributes = element.attributes.where((a) => a.name.qualified != 'xmlns').toList()
    ..sort((a, b) => a.name.local.compareTo(b.name.local));
  for (final attribute in attributes) {
    out.write(' ${attribute.name.local}="${_escapeAttribute(attribute.value)}"');
  }
  out.write('>');
  for (final child in element.children) {
    if (child is XmlElement) {
      _render(child, out, renderedNamespace: namespace, inheritedNamespace: namespace);
    } else if (child is XmlText || child is XmlCDATA) {
      out.write(_escapeText(child.value ?? ''));
    }
  }
  out.write('</${element.name.local}>');
}

String _escapeText(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\r', '&#xD;');

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('"', '&quot;')
    .replaceAll('\t', '&#x9;')
    .replaceAll('\n', '&#xA;')
    .replaceAll('\r', '&#xD;');
