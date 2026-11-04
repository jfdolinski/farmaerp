import 'package:flutter/material.dart';

void main() {
  runApp(const FarmaErpPdvApp());
}

class FarmaErpPdvApp extends StatelessWidget {
  const FarmaErpPdvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'FarmaERP PDV',
      home: Scaffold(body: Center(child: Text('FarmaERP PDV'))),
    );
  }
}
