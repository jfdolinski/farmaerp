import 'dart:async';

import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;

import '../ui/caps.dart';
import 'display_settings.dart';
import 'pos_controller.dart';

/// Barra inferior fixa do caixa (e do orçamento): loja, terminal, operador e turno, vendedor,
/// internet e envios, data e hora e a versão. Sem valores do turno: o fechamento é cego.
class PosStatusBar extends StatefulWidget {
  const PosStatusBar({super.key, required this.controller, required this.online, this.appVersion});

  final PosController controller;
  final bool online;
  final String? appVersion;

  @override
  State<PosStatusBar> createState() => _PosStatusBarState();
}

class _PosStatusBarState extends State<PosStatusBar> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
  static String _time(DateTime value) => '${_two(value.hour)}:${_two(value.minute)}';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final database = controller.database;
    final branch = (database.fiscal?['branch'] as Map?)?['name'] as String?;
    final number = controller.terminalNumber();
    final now = DateTime.now();
    final session = controller.session;
    final lastSync = database.syncState.lastPullAt?.toLocal();
    final pending = database.outboxPending;
    final colors = Theme.of(context).colorScheme;
    final parts = <(String, String)>[
      ('loja', '${branch ?? 'Loja'} · ${TerminalKind.of(database.terminalProfile).label} ${number ?? '-'}'),
      if (!controller.quoteMode)
        ('operador', controller.operator == null
            ? 'Sem operador'
            : 'Operador: ${controller.operator!.name}${session == null ? '' : ' · turno desde ${_time(session.openedAt.toLocal())}'}'),
      ('vendedor', 'Vendedor: ${controller.cart.seller?.name ?? '—'}'),
      ('internet', [
        widget.online ? 'Online' : 'Sem internet: as vendas sobem quando voltar',
        if (pending > 0) '$pending a enviar',
        if (lastSync != null) 'sincronizado às ${_time(lastSync)}',
      ].join(' · ')),
      ('agora', '${_two(now.day)}/${_two(now.month)}/${now.year} ${_time(now)}'),
      if (widget.appVersion != null) ('versao', 'v${widget.appVersion}'),
    ];
    return Material(
      key: const Key('pos-status-bar'),
      color: widget.online ? colors.surfaceContainerHighest : colors.errorContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              for (final (key, text) in parts)
                Text(text, key: Key('status-$key'), style: key == 'internet' && !widget.online ? const TextStyle(fontWeight: FontWeight.bold) : null),
            ],
          ),
        ),
      ),
    );
  }
}
