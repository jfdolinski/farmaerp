import 'package:flutter/material.dart';

/// Visual "balcão de farmácia" do PDV: fundo neutro e frio, superfícies brancas e a cor do terminal
/// (escolhida em Aparência) só na estrutura: foco, botão principal e faixas de destaque.
abstract final class PdvColors {
  /// Texto.
  static const ink = Color(0xFF1C2430);

  /// Texto de apoio.
  static const inkSoft = Color(0xFF4A5563);

  /// Fundo da tela.
  static const paper = Color(0xFFEEF1F4);

  /// Painéis, janelas e campos.
  static const surface = Color(0xFFFFFFFF);

  /// Contornos e divisórias.
  static const line = Color(0xFFCCD3DB);

  static const ok = Color(0xFF1E7A46);
  static const attention = Color(0xFF9A5B00);
  static const error = Color(0xFFB3261E);
}

/// Medidas do visual: cantos por hierarquia (painel > campo) e a espessura do foco.
abstract final class PdvShape {
  static const panel = 14.0;
  static const field = 8.0;
  static const button = 10.0;
  static const focusWidth = 3.0;
}

/// Algarismos de largura fixa: valores e quantidades alinham nas colunas.
const tabularFigures = [FontFeature.tabularFigures()];

/// Valor grande (total, troco).
TextStyle moneyStyle(BuildContext context, {double size = 40, Color? color}) => TextStyle(
  fontSize: size,
  fontWeight: FontWeight.w700,
  height: 1.1,
  color: color ?? PdvColors.ink,
  fontFeatures: tabularFigures,
);

/// Aplica o visual do PDV sobre o tema com a cor do terminal.
ThemeData pdvDecorate(ThemeData base, Color tone) {
  final scheme = base.colorScheme.copyWith(
    surface: PdvColors.surface,
    onSurface: PdvColors.ink,
    onSurfaceVariant: PdvColors.inkSoft,
    outline: PdvColors.inkSoft,
    outlineVariant: PdvColors.line,
    error: PdvColors.error,
  );
  TextStyle? tab(TextStyle? style) => style?.copyWith(fontFeatures: tabularFigures, color: style.color ?? PdvColors.ink);
  final text = base.textTheme;
  final textTheme = text.copyWith(
    displayLarge: tab(text.displayLarge),
    displayMedium: tab(text.displayMedium),
    displaySmall: tab(text.displaySmall),
    headlineLarge: tab(text.headlineLarge),
    headlineMedium: tab(text.headlineMedium),
    headlineSmall: tab(text.headlineSmall),
    titleLarge: tab(text.titleLarge?.copyWith(fontWeight: text.titleLarge?.fontWeight ?? FontWeight.w600)),
    titleMedium: tab(text.titleMedium),
    titleSmall: tab(text.titleSmall),
    bodyLarge: tab(text.bodyLarge),
    bodyMedium: tab(text.bodyMedium),
    bodySmall: tab(text.bodySmall?.copyWith(color: PdvColors.inkSoft)),
    labelLarge: tab(text.labelLarge),
    labelMedium: tab(text.labelMedium),
    labelSmall: tab(text.labelSmall),
  );
  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(PdvShape.field),
    borderSide: BorderSide(color: color, width: width),
  );
  // Foco visível em todo botão: contorno no tom do terminal.
  WidgetStateProperty<BorderSide?> focusSide(BorderSide? normal) => WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.focused) ? BorderSide(color: tone, width: PdvShape.focusWidth) : normal,
  );
  final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(PdvShape.button)),
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: PdvColors.paper,
    textTheme: textTheme,
    dividerTheme: const DividerThemeData(color: PdvColors.line, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: PdvColors.surface,
      border: border(PdvColors.line),
      enabledBorder: border(PdvColors.line),
      focusedBorder: border(tone, PdvShape.focusWidth),
      errorBorder: border(PdvColors.error),
      focusedErrorBorder: border(PdvColors.error, PdvShape.focusWidth),
      disabledBorder: border(PdvColors.line.withValues(alpha: 0.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: PdvColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PdvShape.panel)),
      titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        shape: buttonShape,
        side: focusSide(null),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        shape: buttonShape,
        side: focusSide(const BorderSide(color: PdvColors.line)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 44)),
        shape: buttonShape,
        side: focusSide(null),
      ),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: PdvColors.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: PdvColors.paper,
      headerForegroundColor: PdvColors.ink,
      dividerColor: PdvColors.line,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PdvShape.panel)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: PdvColors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PdvShape.button)),
    ),
  );
}
