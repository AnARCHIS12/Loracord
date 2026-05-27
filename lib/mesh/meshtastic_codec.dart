import 'dart:math';
import 'dart:typed_data';

const int meshtasticBroadcast = 0xffffffff;
const int meshtasticPrivateAppPort = 256;

class MeshtasticClientCodec {
  MeshtasticClientCodec({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  Uint8List encodePrivateAppPacket(
    Uint8List payload, {
    int channel = 0,
    int hopLimit = 3,
    bool wantAck = true,
  }) {
    final data = _ProtoWriter()
      ..writeVarint(1, meshtasticPrivateAppPort)
      ..writeBytes(2, payload);

    final meshPacket = _ProtoWriter()
      ..writeVarint(2, meshtasticBroadcast)
      ..writeVarint(3, channel)
      ..writeBytes(4, data.takeBytes())
      ..writeVarint(5, _random.nextInt(0x7fffffff))
      ..writeVarint(8, hopLimit)
      ..writeVarint(9, wantAck ? 1 : 0);

    final toRadio = _ProtoWriter()..writeBytes(1, meshPacket.takeBytes());
    return toRadio.takeBytes();
  }

  Uint8List? tryDecodePrivateAppPayload(Uint8List fromRadio) {
    final packetBytes = _fieldBytes(fromRadio, 1);
    if (packetBytes == null) return null;
    final decodedBytes = _fieldBytes(packetBytes, 4);
    if (decodedBytes == null) return null;
    final port = _fieldVarint(decodedBytes, 1);
    if (port != meshtasticPrivateAppPort) return null;
    return _fieldBytes(decodedBytes, 2);
  }
}

class _ProtoWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeVarint(int field, int value) {
    _writeKey(field, 0);
    _writeVarint(value);
  }

  void writeBytes(int field, Uint8List value) {
    _writeKey(field, 2);
    _writeVarint(value.length);
    _builder.add(value);
  }

  Uint8List takeBytes() => _builder.takeBytes();

  void _writeKey(int field, int wireType) =>
      _writeVarint((field << 3) | wireType);

  void _writeVarint(int value) {
    var v = value;
    while (v > 0x7f) {
      _builder.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _builder.addByte(v & 0x7f);
  }
}

Uint8List? _fieldBytes(Uint8List data, int wantedField) {
  final reader = _ProtoReader(data);
  while (!reader.isDone) {
    final field = reader.nextField();
    if (field == null) return null;
    if (field.number == wantedField && field.wireType == 2) {
      return reader.readBytes();
    }
    reader.skip(field.wireType);
  }
  return null;
}

int? _fieldVarint(Uint8List data, int wantedField) {
  final reader = _ProtoReader(data);
  while (!reader.isDone) {
    final field = reader.nextField();
    if (field == null) return null;
    if (field.number == wantedField && field.wireType == 0) {
      return reader.readVarint();
    }
    reader.skip(field.wireType);
  }
  return null;
}

class _ProtoField {
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

class _ProtoReader {
  _ProtoReader(this.data);

  final Uint8List data;
  int offset = 0;

  bool get isDone => offset >= data.length;

  _ProtoField? nextField() {
    if (isDone) return null;
    final key = readVarint();
    return _ProtoField(key >> 3, key & 0x7);
  }

  int readVarint() {
    var shift = 0;
    var result = 0;
    while (offset < data.length) {
      final byte = data[offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('Invalid protobuf varint');
    }
    throw const FormatException('Truncated protobuf varint');
  }

  Uint8List readBytes() {
    final length = readVarint();
    if (offset + length > data.length) {
      throw const FormatException('Truncated protobuf bytes field');
    }
    final bytes = Uint8List.sublistView(data, offset, offset + length);
    offset += length;
    return bytes;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        return;
      case 1:
        offset += 8;
        break;
      case 2:
        readBytes();
        return;
      case 5:
        offset += 4;
        break;
      default:
        throw FormatException('Unsupported protobuf wire type $wireType');
    }
    if (offset > data.length) {
      throw const FormatException('Truncated protobuf field');
    }
  }
}
