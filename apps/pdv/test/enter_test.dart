import 'package:farmaerp_pdv/ui/caps.dart' as pdv;
import 'package:farmaerp_pdv/ui/date_field.dart';
import 'package:farmaerp_pdv/ui/enter_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Campo do PDV com chave.
Widget field(String key, {ValueChanged<String>? onSubmitted, int? maxLines = 1, bool readOnly = false}) => SizedBox(
  width: 200,
  child: pdv.TextField(
    key: Key(key),
    controller: TextEditingController(),
    onSubmitted: onSubmitted,
    maxLines: maxLines,
    readOnly: readOnly,
    decoration: pdv.InputDecoration(labelText: key),
  ),
);

Future<void> openDialog(WidgetTester tester, WidgetBuilder builder) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(onPressed: () => showDialog<void>(context: context, builder: builder), child: const Text('abrir')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

bool focused(WidgetTester tester, String key) {
  final editable = tester.widget<EditableText>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText)));
  return editable.focusNode.hasFocus;
}

Future<void> enter(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.next);
  await tester.pumpAndSettle();
}

void main() {
  group('Enter nas janelas', () {
    testWidgets('vai de campo em campo na ordem de leitura e, no último, aciona o botão principal', (tester) async {
      var confirmed = 0;
      var canceled = 0;
      await openDialog(tester, (context) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [field('b'), field('c')]),
          field('d'),
        ]),
        // O primeiro campo fica embaixo na árvore, mas em cima na tela: vale a tela.
        title: field('a'),
        actions: [
          TextButton(onPressed: () => canceled += 1, child: const Text('Cancelar')),
          FilledButton(onPressed: () => confirmed += 1, child: const Text('Confirmar')),
        ],
      ));
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      for (final next in ['b', 'c', 'd']) {
        await enter(tester);
        expect(focused(tester, next), isTrue, reason: 'Enter deveria ir para $next');
      }
      expect(confirmed, 0);
      await enter(tester);
      expect(confirmed, 1);
      expect(canceled, 0);
    });

    testWidgets('pula botões e caixas de marcação; entra na lista de escolha', (tester) async {
      String? chosen;
      await openDialog(tester, (context) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          field('a'),
          OutlinedButton(onPressed: () {}, child: const Text('Buscar')),
          Checkbox(value: false, onChanged: (_) {}),
          DropdownButton<String>(
            key: const Key('list'),
            value: chosen,
            items: const [DropdownMenuItem(value: 'x', child: Text('x'))],
            onChanged: (value) => chosen = value,
          ),
          field('b'),
        ]),
      ));
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      await enter(tester);
      final focus = FocusManager.instance.primaryFocus!;
      expect(focus.context!.findAncestorWidgetOfExactType<DropdownButton<String>>(), isNotNull);
    });

    testWidgets('sem botão principal ou com dois, o último campo não aciona nada', (tester) async {
      var a = 0;
      var b = 0;
      await openDialog(tester, (context) => AlertDialog(
        content: field('only'),
        actions: [
          FilledButton(onPressed: () => a += 1, child: const Text('Um')),
          FilledButton(onPressed: () => b += 1, child: const Text('Outro')),
        ],
      ));
      await tester.tap(find.byKey(const Key('only')));
      await tester.pump();
      await enter(tester);
      expect([a, b], [0, 0]);
      expect(focused(tester, 'only'), isTrue);
    });

    testWidgets('botão principal desabilitado não conta', (tester) async {
      var other = 0;
      await openDialog(tester, (context) => AlertDialog(
        content: field('only'),
        actions: [
          const FilledButton(onPressed: null, child: Text('Confirmar')),
          FilledButton(onPressed: () => other += 1, child: const Text('Liberar')),
        ],
      ));
      await tester.tap(find.byKey(const Key('only')));
      await tester.pump();
      await enter(tester);
      expect(other, 1);
    });

    testWidgets('EnterForm escolhe a ação principal e limita o caminho ao bloco', (tester) async {
      var submitted = 0;
      var button = 0;
      await openDialog(tester, (context) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          EnterForm(onSubmit: () => submitted += 1, child: Column(children: [field('a'), field('b')])),
          field('fora'),
        ]),
        actions: [FilledButton(onPressed: () => button += 1, child: const Text('Outro'))],
      ));
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      await enter(tester);
      expect(focused(tester, 'b'), isTrue);
      await enter(tester);
      expect(submitted, 1);
      expect(button, 0);
    });

    testWidgets('campo com ação própria no Enter continua com ela', (tester) async {
      final seen = <String>[];
      await openDialog(tester, (context) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [field('a', onSubmitted: seen.add), field('b')]),
      ));
      await tester.enterText(find.byKey(const Key('a')), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(seen, ['X']);
      expect(focused(tester, 'b'), isFalse);
    });

    test('campo de várias linhas e campo só de leitura ficam como eram', () {
      final multi = pdv.TextField(controller: TextEditingController(), maxLines: 3);
      expect(multi.onSubmitted, isNull);
      expect(multi.onEditingComplete, isNull);
      expect(multi.textInputAction, isNull);
      final readOnly = pdv.TextField(controller: TextEditingController(), readOnly: true);
      expect(readOnly.onSubmitted, isNull);
      final unlimited = pdv.TextField(controller: TextEditingController(), maxLines: null);
      expect(unlimited.onSubmitted, isNull);
      final single = pdv.TextField(controller: TextEditingController());
      expect(single.onSubmitted, isNotNull);
      expect(single.onEditingComplete, isNotNull);
      expect(single.textInputAction, TextInputAction.next);
      final own = pdv.TextField(controller: TextEditingController(), onEditingComplete: () {});
      expect(own.onSubmitted, isNull);
      final action = pdv.TextField(controller: TextEditingController(), textInputAction: TextInputAction.search);
      expect(action.textInputAction, TextInputAction.search);
    });

    testWidgets('na tela de vendas (fora de janela) o último campo não aciona botão', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [field('a'), FilledButton(onPressed: () => pressed += 1, child: const Text('Finalizar'))]),
        ),
      ));
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      await enter(tester);
      expect(pressed, 0);
    });
  });

  group('campo de data', () {
    test('confere o dia que existe', () {
      expect(parseBrDate('29/02/2024'), DateTime(2024, 2, 29));
      expect(parseBrDate('29/02/2025'), isNull);
      expect(parseBrDate('31/04/2026'), isNull);
      expect(parseBrDate('00/01/2026'), isNull);
      expect(parseBrDate('01/13/2026'), isNull);
      expect(parseBrDate('01/01/1899'), isNull);
      expect(parseBrDate(' 01/01/1900 '), DateTime(1900));
      expect(parseBrDate('1/1/2026'), isNull);
      expect(parseBrDate(''), isNull);
      expect(brDate(DateTime(2026, 5, 3)), '03/05/2026');
    });

    test('a máscara põe as barras e limita a oito números', () {
      expect(DateMaskFormatter.mask('1'), '1');
      expect(DateMaskFormatter.mask('12'), '12');
      expect(DateMaskFormatter.mask('120'), '12/0');
      expect(DateMaskFormatter.mask('1205'), '12/05');
      expect(DateMaskFormatter.mask('12052'), '12/05/2');
      expect(DateMaskFormatter.mask('12052026'), '12/05/2026');
      expect(DateMaskFormatter.mask('120520269'), '12/05/2026');
      expect(DateMaskFormatter.mask('12/05/2026'), '12/05/2026');
      expect(DateMaskFormatter.mask('ab'), '');
    });

    Future<TextEditingController> pumpDate(WidgetTester tester, {List<String>? changes}) async {
      final controller = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: Column(children: [
            DateField(key: const Key('date'), controller: controller, label: 'Nascimento', onChanged: changes?.add),
            field('next'),
          ]),
        ),
      ));
      return controller;
    }

    testWidgets('digitando só os números, a data sai formatada', (tester) async {
      final controller = await pumpDate(tester);
      await tester.enterText(find.byKey(const Key('date')), '12052026');
      expect(controller.text, '12/05/2026');
    });

    testWidgets('ao sair do campo, data que não existe avisa; corrigida, o aviso some', (tester) async {
      final controller = await pumpDate(tester);
      await tester.tap(find.byKey(const Key('date')));
      await tester.enterText(find.byKey(const Key('date')), '31022026');
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsNothing);
      await tester.tap(find.byKey(const Key('next')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsOneWidget);
      // Voltando ao campo para corrigir, o aviso continua até a data ficar certa.
      await tester.tap(find.byKey(const Key('date')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('date')), '3102');
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('date')), '28022026');
      await tester.pump();
      expect(controller.text, '28/02/2026');
      expect(find.text('DATA INVÁLIDA'), findsNothing);
    });

    testWidgets('incompleta também avisa; vazia não', (tester) async {
      await pumpDate(tester);
      await tester.tap(find.byKey(const Key('date')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('next')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsNothing);
      await tester.enterText(find.byKey(const Key('date')), '1205');
      await tester.tap(find.byKey(const Key('next')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsOneWidget);
    });

    testWidgets('o calendário abre pelo botão e pelo Alt+seta para baixo e preenche a data', (tester) async {
      final changes = <String>[];
      final controller = await pumpDate(tester, changes: changes);
      await tester.enterText(find.byKey(const Key('date')), '10052026');
      await tester.tap(find.byKey(const Key('date-calendar')));
      await tester.pumpAndSettle();
      expect(find.text('ESCOLHA A DATA'), findsOneWidget);
      await tester.tap(find.text('15'));
      await tester.tap(find.text('USAR ESTA DATA'));
      await tester.pumpAndSettle();
      expect(controller.text, '15/05/2026');
      expect(changes.last, '15/05/2026');
      expect(focused(tester, 'date'), isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.text('ESCOLHA A DATA'), findsOneWidget);
      await tester.tap(find.text('VOLTAR'));
      await tester.pumpAndSettle();
      expect(controller.text, '15/05/2026');
      expect(focused(tester, 'date'), isTrue);
    });

    testWidgets('campo que já vem com data errada só avisa ao sair dele', (tester) async {
      final controller = await pumpDate(tester);
      controller.text = '12/13';
      await tester.tap(find.byKey(const Key('date')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsNothing);
      await tester.tap(find.byKey(const Key('next')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsOneWidget);
    });

    testWidgets('data escolhida no calendário tira o aviso de data inválida', (tester) async {
      final controller = await pumpDate(tester);
      await tester.enterText(find.byKey(const Key('date')), '1005');
      await tester.tap(find.byKey(const Key('next')));
      await tester.pump();
      expect(find.text('DATA INVÁLIDA'), findsOneWidget);
      await tester.tap(find.byKey(const Key('date-calendar')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.tap(find.text('USAR ESTA DATA'));
      await tester.pumpAndSettle();
      expect(parseBrDate(controller.text)?.day, 15);
      expect(find.text('DATA INVÁLIDA'), findsNothing);
    });

    testWidgets('Enter no campo de data vai para o próximo', (tester) async {
      await openDialog(tester, (context) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DateField(key: const Key('date'), controller: TextEditingController(), label: 'Data'),
          field('next'),
        ]),
      ));
      await tester.tap(find.byKey(const Key('date')));
      await tester.pump();
      await enter(tester);
      expect(focused(tester, 'next'), isTrue);
    });
  });
}
