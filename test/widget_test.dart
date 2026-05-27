import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loracord/domain/entities.dart';
import 'package:loracord/mesh/loracord_crypto.dart';
import 'package:loracord/mesh/loracord_protocol.dart';
import 'package:loracord/mesh/meshtastic_codec.dart';

void main() {
  test('Initial state starts without a default guild', () {
    final state = LoracordState.seed();

    expect(state.guilds, isEmpty);
    expect(state.channels, isEmpty);
    expect(state.messagesForCurrentConversation(), isEmpty);
    expect(state.hasGuilds, isFalse);
  });

  test('Loracord protocol fragments and reassembles UTF-8 messages', () {
    const protocol = LoracordProtocol(maxLoraPayloadBytes: 64);
    final frames = protocol.fragmentText(
      type: LoracordFrameType.channelText,
      messageId: 'm00000001',
      guildId: 'g00000001',
      channelId: 'c00000001',
      senderId: 'u00000001',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      text:
          'Message terrain tres compact avec accents et fragmentation automatique.',
    );

    expect(frames.length, greaterThan(1));

    final reassembler = LoracordReassembler();
    ReassembledLoracordMessage? complete;
    for (final raw in frames.reversed) {
      complete = reassembler.accept(LoracordFrame.tryDecode(raw)!);
    }

    expect(complete, isNotNull);
    expect(
      complete!.text,
      'Message terrain tres compact avec accents et fragmentation automatique.',
    );
    expect(complete.guildId, 'g00000001');
    expect(complete.channelId, 'c00000001');
    expect(complete.senderId, 'u00000001');
    expect(complete.fragmentCount, frames.length);
  });

  test('Meshtastic codec wraps private app payload in ToRadio protobuf', () {
    final codec = MeshtasticClientCodec();
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    final toRadio = codec.encodePrivateAppPacket(payload);

    expect(toRadio.first, 0x0a);
    expect(toRadio.length, greaterThan(payload.length));
  });

  test('Meshtastic codec can address a direct node packet', () {
    final codec = MeshtasticClientCodec();
    final toRadio = codec.encodePrivateAppPacket(
      Uint8List.fromList([1, 2, 3, 4]),
      to: 0x1234abcd,
    );

    expect(toRadio, containsAllInOrder([0x15, 0xcd, 0xab, 0x34, 0x12]));
    expect(codec.encodeWantConfig(), containsAllInOrder([0x18, 0x01]));
  });

  test('Sync requests stay compact and parse after reassembly', () {
    const protocol = LoracordProtocol(maxLoraPayloadBytes: 80);
    final frames = protocol.syncRequest(
      messageId: 'm00000002',
      guildId: 'g00000000',
      channelId: 'u00000009',
      senderId: 'u00000001',
      since: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      direct: true,
    );

    final reassembled = LoracordReassembler().accept(
      LoracordFrame.tryDecode(frames.single)!,
    );
    final request = LoracordSyncRequest.tryParse(reassembled!.text);

    expect(reassembled.type, LoracordFrameType.syncRequest);
    expect(reassembled.channelId, 'u00000009');
    expect(request, isNotNull);
    expect(request!.direct, isTrue);
    expect(request.since.millisecondsSinceEpoch, 1700000000000);
  });

  test('Loracord encrypts channel payloads before fragmentation', () async {
    final key = newCryptoKey();
    final crypto = LoracordCrypto();
    const protocol = LoracordProtocol(maxLoraPayloadBytes: 80);
    final encrypted = await crypto.encryptText(
      key: key,
      messageId: 'm00000003',
      guildId: 'g00000001',
      channelId: 'c00000001',
      senderId: 'u00000001',
      text: 'secret terrain',
    );

    expect(String.fromCharCodes(encrypted), isNot(contains('secret terrain')));

    final frames = protocol.fragmentBytes(
      type: LoracordFrameType.channelText,
      messageId: 'm00000003',
      guildId: 'g00000001',
      channelId: 'c00000001',
      senderId: 'u00000001',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      payload: encrypted,
      encrypted: true,
    );
    final reassembler = LoracordReassembler();
    ReassembledLoracordMessage? complete;
    for (final frame in frames) {
      complete = reassembler.accept(LoracordFrame.tryDecode(frame)!);
    }

    expect(complete!.encrypted, isTrue);
    final clear = await crypto.decryptText(
      key: key,
      messageId: complete.messageId,
      guildId: complete.guildId,
      channelId: complete.channelId,
      senderId: complete.senderId,
      payload: complete.payload,
    );
    expect(clear, 'secret terrain');
  });

  test('Direct invites derive the same DM key with X25519', () async {
    final crypto = LoracordCrypto();
    final alice = await crypto.newDirectIdentity();
    final bob = await crypto.newDirectIdentity();

    final aliceKey = await crypto.deriveDirectKey(
      selfId: 'u00000001',
      peerId: 'u00000002',
      privateKey: alice.privateKey,
      selfPublicKey: alice.publicKey,
      peerPublicKey: bob.publicKey,
    );
    final bobKey = await crypto.deriveDirectKey(
      selfId: 'u00000002',
      peerId: 'u00000001',
      privateKey: bob.privateKey,
      selfPublicKey: bob.publicKey,
      peerPublicKey: alice.publicKey,
    );

    expect(aliceKey, bobKey);
    expect(aliceKey, hasLength(64));
  });
}
