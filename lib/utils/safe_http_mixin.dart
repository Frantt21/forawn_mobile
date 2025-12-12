import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Mixin para manejo seguro de peticiones HTTP
/// Previene crashes cuando el widget se destruye durante una petición
mixin SafeHttpMixin<T extends StatefulWidget> on State<T> {
  final List<http.Client> _activeClients = [];
  final List<Timer> _activeTimers = [];
  bool _isDisposed = false;

  /// Cliente HTTP que se cancela automáticamente al destruir el widget
  http.Client createSafeClient() {
    final client = http.Client();
    _activeClients.add(client);
    return client;
  }

  /// Ejecuta una petición HTTP de forma segura
  /// Retorna null si el widget fue destruido durante la petición
  Future<http.Response?> safeHttpGet(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_isDisposed) return null;

    final client = createSafeClient();
    try {
      final response = await client.get(url, headers: headers).timeout(timeout);

      // Verificar si el widget sigue montado
      if (_isDisposed || !mounted) {
        return null;
      }

      return response;
    } catch (e) {
      if (_isDisposed || !mounted) {
        return null;
      }
      rethrow;
    } finally {
      _activeClients.remove(client);
      client.close();
    }
  }

  /// Ejecuta una petición POST de forma segura
  Future<http.Response?> safeHttpPost(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_isDisposed) return null;

    final client = createSafeClient();
    try {
      final response = await client
          .post(url, headers: headers, body: body)
          .timeout(timeout);

      if (_isDisposed || !mounted) {
        return null;
      }

      return response;
    } catch (e) {
      if (_isDisposed || !mounted) {
        return null;
      }
      rethrow;
    } finally {
      _activeClients.remove(client);
      client.close();
    }
  }

  /// Crea un Timer seguro que se cancela automáticamente
  Timer createSafeTimer(Duration duration, void Function() callback) {
    final timer = Timer(duration, () {
      if (!_isDisposed && mounted) {
        callback();
      }
    });
    _activeTimers.add(timer);
    return timer;
  }

  /// Crea un Timer periódico seguro
  Timer createSafePeriodicTimer(
    Duration duration,
    void Function(Timer) callback,
  ) {
    final timer = Timer.periodic(duration, (timer) {
      if (!_isDisposed && mounted) {
        callback(timer);
      } else {
        timer.cancel();
      }
    });
    _activeTimers.add(timer);
    return timer;
  }

  /// Ejecuta setState de forma segura
  void safeSetState(VoidCallback fn) {
    if (!_isDisposed && mounted) {
      setState(fn);
    }
  }

  /// Limpia todos los recursos activos
  void _cleanup() {
    _isDisposed = true;

    // Cancelar todos los clientes HTTP activos
    for (final client in _activeClients) {
      try {
        client.close();
      } catch (_) {}
    }
    _activeClients.clear();

    // Cancelar todos los timers activos
    for (final timer in _activeTimers) {
      try {
        timer.cancel();
      } catch (_) {}
    }
    _activeTimers.clear();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}

/// Token de cancelación para peticiones HTTP personalizadas
class HttpCancelToken {
  bool _isCancelled = false;
  final List<Completer> _completers = [];

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
    for (final completer in _completers) {
      if (!completer.isCompleted) {
        completer.completeError(HttpCancelledException());
      }
    }
    _completers.clear();
  }

  void checkCancelled() {
    if (_isCancelled) {
      throw HttpCancelledException();
    }
  }

  void registerCompleter(Completer completer) {
    _completers.add(completer);
  }
}

/// Excepción lanzada cuando una petición HTTP es cancelada
class HttpCancelledException implements Exception {
  final String message;

  HttpCancelledException([this.message = 'HTTP request was cancelled']);

  @override
  String toString() => message;
}
