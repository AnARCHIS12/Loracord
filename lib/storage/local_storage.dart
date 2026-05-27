import 'package:flutter/services.dart';

abstract class LocalStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class NativeLocalStorage implements LocalStorage {
  const NativeLocalStorage({
    MethodChannel channel = const MethodChannel('loracord/storage'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});
}

class MemoryLocalStorage implements LocalStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
