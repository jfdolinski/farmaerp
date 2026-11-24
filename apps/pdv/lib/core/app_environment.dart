import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;

import '../ui/caps.dart';

/// Ambiente definido na compilação: `--dart-define=APP_ENV=homologation`.
const appEnvironment = String.fromEnvironment(
  'APP_ENV',
  defaultValue: 'development',
);

/// Fora de desenvolvimento, a chave do terminal só conversa com a central por HTTPS.
bool isApiUrlAllowed(String environment, String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return false;
  return environment == 'development' || uri.scheme == 'https';
}

/// Faixa que evita confundir a homologação com a loja real.
class EnvironmentBanner extends StatelessWidget {
  const EnvironmentBanner({
    super.key,
    required this.environment,
    required this.child,
  });

  final String environment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (environment != 'homologation') return child;
    return Column(
      children: [
        Material(
          color: const Color(0xFF8A5300),
          child: SafeArea(
            bottom: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: const Text(
                'HOMOLOGAÇÃO: ambiente de testes, sem dados reais',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
