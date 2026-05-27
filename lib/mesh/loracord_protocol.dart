import 'dart:convert';
import 'dart:typed_data';

const int loracordMagicA = 0x4c;
const int loracordMagicB = 0x43;
const int loracordProtocolVersion = 1;
const int loracordHeaderBytes = 28;
const int defaultMaxLoraPayloadBytes = 180;
const int loracordEncryptedFlag = 0x01;

enum LoracordFrameType {
  channelText(1),
  directText(2),
  invite(3),
  syncOffer(4),
  syncRequest(5);

  const LoracordFrameType(this.code);
  final int code;

  static LoracordFrameType? fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

class LoracordFrame {
  const LoracordFrame({
    required this.type,
    required this.flags,
    required this.totalFragments,
    required this.fragmentIndex,
    required this.ttl,
    required this.messageId,
    required this.guildId,
    required this.channelId,
    required this.senderId,
    required this.createdAtSeconds,
    required this.payload,
  });

  final LoracordFrameType type;
  final int flags;
  final int totalFragments;
  final int fragmentIndex;
  final int ttl;
  final int messageId;
  final int guildId;
  final int channelId;
  final int senderId;
  final int createdAtSeconds;
  final Uint8List payload;

  Uint8List encode() {
    final data = Uint8List(loracordHeaderBytes + payload.length);
    data[0] = loracordMagicA;
    data[1] = loracordMagicB;
    data[2] = loracordProtocolVersion;
    data[3] = type.code;
    data[4] = flags & 0xff;
    data[5] = totalFragments & 0xff;
    data[6] = fragmentIndex & 0xff;
    data[7] = ttl & 0xff;
    _writeU32(data, 8, messageId);
    _writeU32(data, 12, guildId);
    _writeU32(data, 16, channelId);
    _writeU32(data, 20, senderId);
    _writeU32(data, 24, createdAtSeconds);
    data.setRange(loracordHeaderBytes, data.length, payload);
    return data;
  }

  static LoracordFrame? tryDecode(Uint8List data) {
    if (data.length < loracordHeaderBytes) return null;
    if (data[0] != loracordMagicA || data[1] != loracordMagicB) return null;
    if (data[2] != loracordProtocolVersion) return null;
    final type = LoracordFrameType.fromCode(data[3]);
    if (type == null) return null;
    final total = data[5];
    final index = data[6];
    if (total == 0 || index >= total) return null;
    return LoracordFrame(
      type: type,
      flags: data[4],
      totalFragments: total,
      fragmentIndex: index,
      ttl: data[7],
      messageId: _readU32(data, 8),
      guildId: _readU32(data, 12),
      channelId: _readU32(data, 16),
      senderId: _readU32(data, 20),
      createdAtSeconds: _readU32(data, 24),
      payload: Uint8List.sublistView(data, loracordHeaderBytes),
    );
  }
}

class ReassembledLoracordMessage {
  const ReassembledLoracordMessage({
    required this.type,
    required this.messageId,
    required this.guildId,
    required this.channelId,
    required this.senderId,
    required this.createdAt,
    required this.text,
    required this.payload,
    required this.fragmentCount,
    required this.encrypted,
  });

  final LoracordFrameType type;
  final String messageId;
  final String guildId;
  final String channelId;
  final String senderId;
  final DateTime createdAt;
  final String text;
  final Uint8List payload;
  final int fragmentCount;
  final bool encrypted;
}

class LoracordProtocol {
  const LoracordProtocol({
    this.maxLoraPayloadBytes = defaultMaxLoraPayloadBytes,
  });

  final int maxLoraPayloadBytes;

  List<Uint8List> fragmentText({
    required LoracordFrameType type,
    required String messageId,
    required String guildId,
    required String channelId,
    required String senderId,
    required DateTime createdAt,
    required String text,
  }) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    return fragmentBytes(
      type: type,
      messageId: messageId,
      guildId: guildId,
      channelId: channelId,
      senderId: senderId,
      createdAt: createdAt,
      payload: bytes,
    );
  }

  List<Uint8List> fragmentBytes({
    required LoracordFrameType type,
    required String messageId,
    required String guildId,
    required String channelId,
    required String senderId,
    required DateTime createdAt,
    required Uint8List payload,
    bool encrypted = false,
  }) {
    final bytes = payload;
    final chunkSize = maxLoraPayloadBytes - loracordHeaderBytes;
    if (chunkSize < 24) {
      throw StateError('maxLoraPayloadBytes is too small for Loracord frames');
    }
    final total = (bytes.length / chunkSize).ceil().clamp(1, 255).toInt();
    if (total > 255) {
      throw ArgumentError('Message too long for one Loracord transfer');
    }
    final msg = meshHash(messageId);
    final guild = meshHash(guildId);
    final channel = meshHash(channelId);
    final sender = meshHash(senderId);
    final seconds = createdAt.millisecondsSinceEpoch ~/ 1000;
    final frames = <Uint8List>[];

    for (var index = 0; index < total; index++) {
      final start = index * chunkSize;
      final end = (start + chunkSize).clamp(0, bytes.length).toInt();
      final frame = LoracordFrame(
        type: type,
        flags: encrypted ? loracordEncryptedFlag : 0,
        totalFragments: total,
        fragmentIndex: index,
        ttl: 6,
        messageId: msg,
        guildId: guild,
        channelId: channel,
        senderId: sender,
        createdAtSeconds: seconds,
        payload: Uint8List.sublistView(bytes, start, end),
      );
      frames.add(frame.encode());
    }
    return frames;
  }

  List<Uint8List> syncRequest({
    required String messageId,
    required String guildId,
    required String channelId,
    required String senderId,
    required DateTime since,
    required bool direct,
  }) {
    final payload =
        'since=${since.millisecondsSinceEpoch ~/ 1000};direct=${direct ? 1 : 0}';
    return fragmentText(
      type: LoracordFrameType.syncRequest,
      messageId: messageId,
      guildId: guildId,
      channelId: channelId,
      senderId: senderId,
      createdAt: DateTime.now(),
      text: payload,
    );
  }
}

class LoracordSyncRequest {
  const LoracordSyncRequest({required this.since, required this.direct});

  final DateTime since;
  final bool direct;

  static LoracordSyncRequest? tryParse(String payload) {
    final values = <String, String>{};
    for (final part in payload.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      values[part.substring(0, separator)] = part.substring(separator + 1);
    }
    final sinceSeconds = int.tryParse(values['since'] ?? '');
    if (sinceSeconds == null) return null;
    return LoracordSyncRequest(
      since: DateTime.fromMillisecondsSinceEpoch(sinceSeconds * 1000),
      direct: values['direct'] == '1',
    );
  }
}

class LoracordReassembler {
  final Map<int, _FragmentBuffer> _buffers = {};

  ReassembledLoracordMessage? accept(LoracordFrame frame) {
    final buffer = _buffers.putIfAbsent(
      frame.messageId,
      () => _FragmentBuffer(frame),
    );
    buffer.add(frame);
    if (!buffer.isComplete) return null;
    _buffers.remove(frame.messageId);
    return buffer.build();
  }

  void evictOlderThan(Duration maxAge) {
    final cutoff = DateTime.now().subtract(maxAge);
    _buffers.removeWhere((_, value) => value.firstSeen.isBefore(cutoff));
  }
}

class _FragmentBuffer {
  _FragmentBuffer(LoracordFrame first)
    : type = first.type,
      messageId = first.messageId,
      guildId = first.guildId,
      channelId = first.channelId,
      senderId = first.senderId,
      createdAtSeconds = first.createdAtSeconds,
      flags = first.flags,
      total = first.totalFragments,
      firstSeen = DateTime.now();

  final LoracordFrameType type;
  final int messageId;
  final int guildId;
  final int channelId;
  final int senderId;
  final int createdAtSeconds;
  final int flags;
  final int total;
  final DateTime firstSeen;
  final Map<int, Uint8List> fragments = {};

  bool get isComplete => fragments.length == total;

  void add(LoracordFrame frame) {
    if (frame.messageId != messageId || frame.totalFragments != total) return;
    fragments[frame.fragmentIndex] = frame.payload;
  }

  ReassembledLoracordMessage build() {
    final bytes = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      bytes.add(fragments[i]!);
    }
    final payload = bytes.takeBytes();
    final encrypted = (flags & loracordEncryptedFlag) != 0;
    final text = encrypted ? '' : utf8.decode(payload);
    final channelPrefix =
        type == LoracordFrameType.directText ||
            (type == LoracordFrameType.syncRequest && text.contains('direct=1'))
        ? 'u'
        : 'c';
    return ReassembledLoracordMessage(
      type: type,
      messageId: idFromHash('m', messageId),
      guildId: idFromHash('g', guildId),
      channelId: idFromHash(channelPrefix, channelId),
      senderId: idFromHash('u', senderId),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtSeconds * 1000),
      text: text,
      payload: payload,
      fragmentCount: total,
      encrypted: encrypted,
    );
  }
}

int meshHash(String value) {
  final encodedId = _tryParseCompactId(value);
  if (encodedId != null) return encodedId;
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(value)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

String idFromHash(String prefix, int hash) =>
    '$prefix${hash.toRadixString(16).padLeft(8, '0')}';

int? _tryParseCompactId(String value) {
  if (value.length != 9) return null;
  final prefix = value.codeUnitAt(0);
  final isKnownPrefix =
      prefix == 0x67 || prefix == 0x63 || prefix == 0x75 || prefix == 0x6d;
  if (!isKnownPrefix) return null;
  return int.tryParse(value.substring(1), radix: 16);
}

void _writeU32(Uint8List data, int offset, int value) {
  final v = value & 0xffffffff;
  data[offset] = (v >> 24) & 0xff;
  data[offset + 1] = (v >> 16) & 0xff;
  data[offset + 2] = (v >> 8) & 0xff;
  data[offset + 3] = v & 0xff;
}

int _readU32(Uint8List data, int offset) {
  return ((data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3]) &
      0xffffffff;
}
