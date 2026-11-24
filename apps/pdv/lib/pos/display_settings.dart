import 'package:flutter/material.dart';

import '../local/local_database.dart';

/// Tamanho e tipo da fonte do PDV: parâmetro de cada terminal, guardado no banco local e aplicado
/// na hora em todas as telas.
class DisplaySettings extends ChangeNotifier {
  DisplaySettings(this.database) {
    final scale = double.tryParse(database.setting(scaleKey) ?? '');
    _scale = scale != null && scales.contains(scale) ? scale : 1.0;
    final family = database.setting(familyKey);
    _family = families.containsKey(family) ? family! : '';
  }

  static const scaleKey = 'font_scale';
  static const familyKey = 'font_family';

  /// Tamanhos oferecidos (1,0 é o padrão).
  static const scales = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.6];

  /// Fontes do sistema. Vazio é a padrão do PDV; se a fonte faltar na máquina, cai na padrão.
  static const families = {
    '': 'Padrão',
    'Segoe UI': 'Segoe UI',
    'Arial': 'Arial',
    'Verdana': 'Verdana',
    'Tahoma': 'Tahoma',
    'Consolas': 'Consolas (largura fixa)',
  };

  final LocalDatabase database;
  late double _scale;
  late String _family;

  double get scale => _scale;
  String get family => _family;

  void update({double? scale, String? family}) {
    if (scale != null && scales.contains(scale)) {
      _scale = scale;
      database.setSetting(scaleKey, scale.toString());
    }
    if (family != null && families.containsKey(family)) {
      _family = family;
      database.setSetting(familyKey, family.isEmpty ? null : family);
    }
    notifyListeners();
  }

  /// Tema com a fonte escolhida.
  ThemeData theme() => ThemeData(fontFamily: _family.isEmpty ? null : _family);

  /// Aplica o tamanho escolhido sobre o tamanho do sistema.
  Widget apply(BuildContext context, Widget child) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(media.textScaler.scale(1) * _scale)),
      child: child,
    );
  }
}

/// Janela da fonte do terminal: tamanho e tipo, com uma prévia.
Future<void> showDisplaySettings(BuildContext context, DisplaySettings settings) {
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) => AlertDialog(
        key: const Key('display-settings'),
        title: const Text('Fonte do PDV'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<double>(
                key: const Key('font-scale'),
                initialValue: settings.scale,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tamanho'),
                items: [
                  for (final scale in DisplaySettings.scales)
                    DropdownMenuItem(value: scale, child: Text('${(scale * 100).round()}%${scale == 1.0 ? ' (padrão)' : ''}')),
                ],
                onChanged: (value) => settings.update(scale: value),
              ),
              DropdownButtonFormField<String>(
                key: const Key('font-family'),
                initialValue: settings.family,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Fonte'),
                items: [
                  for (final entry in DisplaySettings.families.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) => settings.update(family: value),
              ),
              const SizedBox(height: 16),
              const Text('Prévia: Dipirona Sódica 500 mg · R\$ 12,90', key: Key('font-preview')),
              const SizedBox(height: 8),
              const Text('Vale só para este terminal e fica guardado nele.'),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Fechar'))],
      ),
    ),
  );
}
