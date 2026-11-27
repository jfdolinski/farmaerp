import 'package:flutter/material.dart';

/// Envolve uma janela (ou um bloco de campos): o Enter num campo sem ação própria vai para o próximo
/// campo do bloco; no último, chama [onSubmit] (a ação principal, como "Confirmar").
class EnterForm extends StatelessWidget {
  const EnterForm({super.key, required this.child, this.onSubmit});

  final Widget child;

  /// Ação principal. Nula: o Enter no último campo não faz nada.
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) => child;
}

/// O que o Enter alcança: campos de texto e listas de escolha. Botões ficam de fora, para o Enter
/// nunca cair em "Cancelar" por engano, e caixas de marcação também (nelas o Enter marca e desmarca).
bool _isEntry(FocusNode node) {
  final context = node.context;
  if (context == null || !node.canRequestFocus || node.skipTraversal) return false;
  var found = false;
  var depth = 0;
  // O nó de foco fica alguns níveis abaixo do controle dono dele.
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is EditableText || widget is DropdownButton) {
      found = true;
      return false;
    }
    depth += 1;
    return depth < 24;
  });
  return found;
}

EnterForm? _formOf(BuildContext? context) => context?.findAncestorWidgetOfExactType<EnterForm>();

/// Ordem de leitura: de cima para baixo e, na mesma linha, da esquerda para a direita.
int _reading(FocusNode a, FocusNode b) {
  final ra = a.rect;
  final rb = b.rect;
  final sameRow = (ra.center.dy - rb.center.dy).abs() < (ra.height < rb.height ? ra.height : rb.height) / 2;
  if (!sameRow) return ra.top.compareTo(rb.top);
  return ra.left.compareTo(rb.left);
}

/// Enter num campo sem ação própria: próximo campo do bloco, ou a ação principal no último.
void enterAdvance([String? _]) {
  final current = FocusManager.instance.primaryFocus;
  final scope = current?.nearestScope;
  if (current == null || scope == null) return;
  final form = _formOf(current.context);
  final entries = scope.traversalDescendants
      .where((node) => node == current || (_isEntry(node) && _formOf(node.context) == form))
      .toList()
    ..sort(_reading);
  final index = entries.indexOf(current);
  if (index >= 0 && index + 1 < entries.length) {
    entries[index + 1].requestFocus();
    return;
  }
  final submit = form?.onSubmit ?? _primaryOfDialog(current.context, scope.context);
  submit?.call();
}

/// Numa janela (não na tela de vendas), a ação principal é o único botão cheio habilitado. Com
/// nenhum ou mais de um, o Enter no último campo não faz nada: o operador escolhe.
VoidCallback? _primaryOfDialog(BuildContext? field, BuildContext? scope) {
  if (field == null || scope == null || ModalRoute.of(field) is! PopupRoute) return null;
  final found = <VoidCallback>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is FilledButton && widget.onPressed != null) found.add(widget.onPressed!);
    element.visitChildElements(visit);
  }
  (scope as Element).visitChildElements(visit);
  return found.length == 1 ? found.single : null;
}

/// Usado no lugar do "concluir edição" padrão, que tiraria o foco do campo antes de avançar.
void keepFocus() {}
