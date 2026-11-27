import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/local_logger.dart';

/// Imagem da tela de entrada vinda da central: só o resumo, para saber se mudou, e o arquivo.
abstract class LoginImageApi {
  /// Resumo (SHA-256) da imagem em uso, ou null quando a plataforma está sem imagem.
  Future<String?> current();

  Future<Uint8List> download();
}

class HttpLoginImageApi implements LoginImageApi {
  HttpLoginImageApi({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  @override
  Future<String?> current() async {
    final response = await _client
        .get(Uri.parse('$baseUrl/public/login-image/info'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('imagem: ${response.statusCode}');
    final body = jsonDecode(response.body);
    return body is Map ? body['sha256'] as String? : null;
  }

  @override
  Future<Uint8List> download() async {
    final response = await _client.get(Uri.parse('$baseUrl/public/login-image')).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw HttpException('imagem: ${response.statusCode}');
    return response.bodyBytes;
  }
}

/// Até 3 MB, como a central aceita.
const loginImageMaxBytes = 3 * 1024 * 1024;

Future<String> sha256Hex(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Guarda a imagem da tela de entrada no caixa, para mostrar mesmo sem internet. Confere a cada
/// sincronização se ela mudou; só baixa de novo quando o resumo é outro.
class LoginImageStore extends ChangeNotifier {
  LoginImageStore({required this.directory, required this.api, this.logger});

  final Directory directory;
  final LoginImageApi api;
  final LocalLogger? logger;

  Uint8List? _bytes;
  String? _sha256;
  bool _refreshing = false;

  /// A imagem guardada, ou null (fica a cor da marca).
  Uint8List? get bytes => _bytes;
  String? get sha256 => _sha256;

  File get _imageFile => File('${directory.path}${Platform.pathSeparator}login_image.bin');
  File get _digestFile => File('${directory.path}${Platform.pathSeparator}login_image.sha256');

  /// Lê a imagem guardada. Arquivo que não confere com o resumo é ignorado (e baixado de novo).
  Future<void> load() async {
    try {
      if (!_imageFile.existsSync() || !_digestFile.existsSync()) return;
      final bytes = await _imageFile.readAsBytes();
      final digest = (await _digestFile.readAsString()).trim();
      if (await sha256Hex(bytes) != digest) return;
      _bytes = bytes;
      _sha256 = digest;
      notifyListeners();
    } catch (error) {
      logger?.info('Imagem da tela de entrada guardada não abriu', fields: {'error': error.runtimeType.toString()});
    }
  }

  /// Confere com a central e baixa se mudou. Sem internet, fica com a que tem.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final digest = await api.current();
      if (digest == _sha256) return;
      if (digest == null) {
        await _remove();
        return;
      }
      final bytes = await api.download();
      if (bytes.length > loginImageMaxBytes || await sha256Hex(bytes) != digest) {
        logger?.info('Imagem da tela de entrada recebida não confere', fields: {'size': bytes.length});
        return;
      }
      await directory.create(recursive: true);
      // Grava ao lado e troca: o caixa nunca fica com meio arquivo.
      final temporary = File('${_imageFile.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(_imageFile.path);
      await _digestFile.writeAsString(digest, flush: true);
      _bytes = bytes;
      _sha256 = digest;
      notifyListeners();
    } catch (error) {
      // Sem internet ou central fora: tenta na próxima sincronização.
      logger?.info('Imagem da tela de entrada não foi conferida', fields: {'error': error.runtimeType.toString()});
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _remove() async {
    for (final file in [_imageFile, _digestFile]) {
      if (file.existsSync()) await file.delete();
    }
    if (_bytes == null && _sha256 == null) return;
    _bytes = null;
    _sha256 = null;
    notifyListeners();
  }
}
