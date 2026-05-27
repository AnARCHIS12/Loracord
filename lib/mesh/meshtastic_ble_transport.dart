import 'dart:async';

import 'package:flutter/services.dart';

import 'mesh_transport.dart';

class MeshtasticBleTransport implements MeshTransport {
  MeshtasticBleTransport({MethodChannel? channel, EventChannel? eventChannel})
    : _channel = channel ?? const MethodChannel('loracord/meshtastic_ble'),
      _eventChannel =
          eventChannel ?? const EventChannel('loracord/meshtastic_ble/events') {
    _nativeEvents = _eventChannel
        .receiveBroadcastStream()
        .map(_parseEvent)
        .asBroadcastStream();
  }

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  late final Stream<MeshTransportEvent> _nativeEvents;

  @override
  Stream<MeshTransportEvent> get events => _nativeEvents;

  @override
  Future<void> requestPermissions() =>
      _channel.invokeMethod<void>('requestPermissions');

  @override
  Future<List<MeshDevice>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _channel.invokeMethod<List<Object?>>('scan', {
      'timeoutMs': timeout.inMilliseconds,
    });
    return (result ?? const [])
        .map(
          (value) => _deviceFromMap(
            (value as Map<Object?, Object?>).cast<String, Object?>(),
          ),
        )
        .toList();
  }

  @override
  Future<void> connect(MeshDevice device) =>
      _channel.invokeMethod<void>('connect', {'id': device.id});

  @override
  Future<void> submitPairingPin(MeshDevice device, String pin) => _channel
      .invokeMethod<void>('submitPairingPin', {'id': device.id, 'pin': pin});

  @override
  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');

  @override
  Future<void> write(Uint8List bytes) =>
      _channel.invokeMethod<void>('write', bytes);

  MeshTransportEvent _parseEvent(Object? raw) {
    final map = (raw as Map<Object?, Object?>).cast<String, Object?>();
    final type = map['type'] as String? ?? 'log';
    switch (type) {
      case 'device':
        return MeshTransportEvent.device(
          MeshTransportStatus.scanning,
          _deviceFromMap(
            (map['device'] as Map<Object?, Object?>).cast<String, Object?>(),
          ),
        );
      case 'pairing':
        return MeshTransportEvent.device(
          MeshTransportStatus.pairing,
          _deviceFromMap(
            (map['device'] as Map<Object?, Object?>).cast<String, Object?>(),
          ),
          message: map['message'] as String?,
        );
      case 'connected':
        return MeshTransportEvent.status(
          MeshTransportStatus.connected,
          message: map['message'] as String?,
        );
      case 'disconnected':
        return MeshTransportEvent.status(
          MeshTransportStatus.disconnected,
          message: map['message'] as String?,
        );
      case 'data':
        return MeshTransportEvent.data(map['bytes'] as Uint8List);
      case 'error':
        return MeshTransportEvent.status(
          MeshTransportStatus.error,
          message: map['message'] as String?,
        );
      default:
        return MeshTransportEvent.status(
          MeshTransportStatus.idle,
          message: map['message'] as String?,
        );
    }
  }

  MeshDevice _deviceFromMap(Map<String, Object?> map) => MeshDevice(
    id: map['id'] as String,
    name: map['name'] as String? ?? 'Meshtastic',
    rssi: map['rssi'] as int?,
  );
}
