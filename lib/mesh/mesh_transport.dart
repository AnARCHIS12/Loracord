import 'dart:async';
import 'dart:typed_data';

enum MeshTransportStatus {
  idle,
  scanning,
  pairing,
  connecting,
  connected,
  disconnected,
  error,
}

class MeshDevice {
  const MeshDevice({
    required this.id,
    required this.name,
    this.rssi,
    this.paired = false,
  });

  final String id;
  final String name;
  final int? rssi;
  final bool paired;
}

class MeshTransportEvent {
  const MeshTransportEvent._({
    required this.status,
    this.device,
    this.data,
    this.message,
  });

  final MeshTransportStatus status;
  final MeshDevice? device;
  final Uint8List? data;
  final String? message;

  factory MeshTransportEvent.status(
    MeshTransportStatus status, {
    String? message,
  }) {
    return MeshTransportEvent._(status: status, message: message);
  }

  factory MeshTransportEvent.device(
    MeshTransportStatus status,
    MeshDevice device, {
    String? message,
  }) {
    return MeshTransportEvent._(
      status: status,
      device: device,
      message: message,
    );
  }

  factory MeshTransportEvent.data(Uint8List data) {
    return MeshTransportEvent._(
      status: MeshTransportStatus.connected,
      data: data,
    );
  }
}

abstract class MeshTransport {
  Stream<MeshTransportEvent> get events;

  Future<void> requestPermissions();

  Future<List<MeshDevice>> scan({
    Duration timeout = const Duration(seconds: 6),
  });

  Future<void> connect(MeshDevice device);

  Future<void> submitPairingPin(MeshDevice device, String pin);

  Future<void> disconnect();

  Future<void> write(Uint8List bytes);
}
