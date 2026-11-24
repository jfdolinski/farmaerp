import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;

import '../local/local_database.dart';
import '../ui/caps.dart';

/// Tipo do terminal, com o nome, o ícone e o tom da cor base: orçamento claro, caixa médio e
/// autoatendimento forte. Assim a loja reconhece cada terminal de longe, e não só pela cor.
enum TerminalKind {
  quote('quote', 'Orçamento', Icons.assignment_outlined, 300),
  cashier('cashier', 'Caixa', Icons.point_of_sale, 600),
  selfService('self_service', 'Autoatendimento', Icons.person_outline, 900);

  const TerminalKind(this.code, this.label, this.icon, this.shade);

  final String code;
  final String label;
  final IconData icon;

  /// Tom dentro da cor base (300 claro, 600 médio, 900 forte).
  final int shade;

  static TerminalKind of(String profile) => values.firstWhere((kind) => kind.code == profile, orElse: () => cashier);
}

/// Aparência do PDV: tamanho, tipo e peso da fonte e a cor base. Parâmetro de cada terminal,
/// guardado no banco local e aplicado na hora em todas as telas.
class DisplaySettings extends ChangeNotifier {
  DisplaySettings(this.database) {
    final scale = double.tryParse(database.setting(scaleKey) ?? '');
    _scale = scale != null && scales.contains(scale) ? scale : 1.0;
    final family = database.setting(familyKey);
    _family = families.containsKey(family) ? family! : '';
    _bold = database.setting(boldKey) == 'true';
    _color = colorOf(database);
  }

  static const scaleKey = 'font_scale';
  static const familyKey = 'font_family';
  static const boldKey = 'font_bold';
  static const colorKey = 'base_color';

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

  /// Cores base. O tom de cada tipo de terminal sai da mesma cor.
  static const colors = <String, (String, MaterialColor)>{
    'blue': ('Azul', Colors.blue),
    'green': ('Verde', Colors.green),
    'teal': ('Verde-água', Colors.teal),
    'purple': ('Roxo', Colors.deepPurple),
    'red': ('Vermelho', Colors.red),
    'orange': ('Laranja', Colors.orange),
    'grey': ('Cinza', Colors.blueGrey),
  };

  /// Cor base guardada no terminal (azul se nada foi escolhido).
  static String colorOf(LocalDatabase database) {
    final value = database.setting(colorKey);
    return colors.containsKey(value) ? value! : 'blue';
  }

  /// Tom do tipo de terminal dentro da cor base.
  static Color toneOf(String color, TerminalKind kind) => (colors[color] ?? colors['blue']!).$2[kind.shade]!;

  /// Texto legível sobre o tom (preto no claro, branco no forte).
  static Color onTone(Color tone) =>
      ThemeData.estimateBrightnessForColor(tone) == Brightness.dark ? Colors.white : Colors.black87;

  final LocalDatabase database;
  late double _scale;
  late String _family;
  late bool _bold;
  late String _color;

  double get scale => _scale;
  String get family => _family;
  bool get bold => _bold;
  String get color => _color;

  void update({double? scale, String? family, bool? bold, String? color}) {
    if (scale != null && scales.contains(scale)) {
      _scale = scale;
      database.setSetting(scaleKey, scale.toString());
    }
    if (family != null && families.containsKey(family)) {
      _family = family;
      database.setSetting(familyKey, family.isEmpty ? null : family);
    }
    if (bold != null) {
      _bold = bold;
      database.setSetting(boldKey, bold ? 'true' : null);
    }
    if (color != null && colors.containsKey(color)) {
      _color = color;
      database.setSetting(colorKey, color);
    }
    notifyListeners();
  }

  /// Tema com a fonte e a cor escolhidas, no tom do tipo do terminal.
  ThemeData theme([TerminalKind? kind]) =>
      themeFor(color: _color, kind: kind ?? TerminalKind.of(database.terminalProfile), family: _family, bold: _bold);

  /// Pinta um tema pronto com o tom do tipo do terminal (a tela do caixa usa o tipo que veio da central).
  static ThemeData tinted(ThemeData base, String color, TerminalKind kind) {
    final tone = toneOf(color, kind);
    return base.copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: tone),
      appBarTheme: AppBarTheme(backgroundColor: tone, foregroundColor: onTone(tone)),
    );
  }

  /// Tema de um tipo de terminal: a cor base no tom dele, na barra do topo e nos destaques.
  static ThemeData themeFor({required String color, required TerminalKind kind, String family = '', bool bold = false}) {
    final tone = toneOf(color, kind);
    final base = ThemeData(
      fontFamily: family.isEmpty ? null : family,
      colorScheme: ColorScheme.fromSeed(seedColor: tone),
      appBarTheme: AppBarTheme(backgroundColor: tone, foregroundColor: onTone(tone)),
    );
    if (!bold) return base;
    TextStyle? heavy(TextStyle? style) => style?.copyWith(fontWeight: FontWeight.bold);
    final text = base.textTheme;
    return base.copyWith(
      textTheme: text.copyWith(
        displayLarge: heavy(text.displayLarge),
        displayMedium: heavy(text.displayMedium),
        displaySmall: heavy(text.displaySmall),
        headlineLarge: heavy(text.headlineLarge),
        headlineMedium: heavy(text.headlineMedium),
        headlineSmall: heavy(text.headlineSmall),
        titleLarge: heavy(text.titleLarge),
        titleMedium: heavy(text.titleMedium),
        titleSmall: heavy(text.titleSmall),
        bodyLarge: heavy(text.bodyLarge),
        bodyMedium: heavy(text.bodyMedium),
        bodySmall: heavy(text.bodySmall),
        labelLarge: heavy(text.labelLarge),
        labelMedium: heavy(text.labelMedium),
        labelSmall: heavy(text.labelSmall),
      ),
    );
  }

  /// Aplica o tamanho escolhido sobre o tamanho do sistema.
  Widget apply(BuildContext context, Widget child) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(media.textScaler.scale(1) * _scale)),
      child: child,
    );
  }
}

/// Janela da aparência do terminal: fonte (tamanho, tipo e negrito) e cor base, com uma prévia
/// dos três tons.
Future<void> showDisplaySettings(BuildContext context, DisplaySettings settings) {
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) => AlertDialog(
        key: const Key('display-settings'),
        title: const Text('Aparência do PDV'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
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
                SwitchListTile(
                  key: const Key('font-bold'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Negrito'),
                  value: settings.bold,
                  onChanged: (value) => settings.update(bold: value),
                ),
                DropdownButtonFormField<String>(
                  key: const Key('base-color'),
                  initialValue: settings.color,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Cor base'),
                  items: [
                    for (final entry in DisplaySettings.colors.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Row(
                          children: [
                            Icon(Icons.circle, color: entry.value.$2[600]),
                            const SizedBox(width: 8),
                            Text(entry.value.$1),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (value) => settings.update(color: value),
                ),
                const SizedBox(height: 12),
                for (final kind in TerminalKind.values)
                  Container(
                    key: Key('tone-${kind.code}'),
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    color: DisplaySettings.toneOf(settings.color, kind),
                    child: Row(
                      children: [
                        Icon(kind.icon, color: DisplaySettings.onTone(DisplaySettings.toneOf(settings.color, kind))),
                        const SizedBox(width: 8),
                        Text(
                          kind.label,
                          style: TextStyle(color: DisplaySettings.onTone(DisplaySettings.toneOf(settings.color, kind))),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                const Text('Prévia: Dipirona Sódica 500 mg · R\$ 12,90', key: Key('font-preview')),
                const SizedBox(height: 8),
                const Text('Vale só para este terminal e fica guardado nele.'),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Fechar'))],
      ),
    ),
  );
}
