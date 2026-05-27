import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int loracordCryptoVersion = 1;
const int loracordAesGcmNonceBytes = 12;
const int loracordAesGcmMacBytes = 16;

class LoracordCrypto {
  LoracordCrypto({AesGcm? algorithm, X25519? keyExchange, Sha256? hash})
    : _algorithm = algorithm ?? AesGcm.with256bits(),
      _keyExchange = keyExchange ?? X25519(),
      _hash = hash ?? Sha256();

  final AesGcm _algorithm;
  final X25519 _keyExchange;
  final Sha256 _hash;

  Future<Uint8List> encryptText({
    required String key,
    required String messageId,
    required String guildId,
    required String channelId,
    required String senderId,
    required String text,
  }) async {
    final secretBox = await _algorithm.encrypt(
      utf8.encode(text),
      secretKey: SecretKey(_decodeKey(key)),
      aad: utf8.encode('$messageId|$guildId|$channelId|$senderId'),
    );
    return Uint8List.fromList([
      loracordCryptoVersion,
      ...secretBox.nonce,
      ...secretBox.mac.bytes,
      ...secretBox.cipherText,
    ]);
  }

  Future<String> decryptText({
    required String key,
    required String messageId,
    required String guildId,
    required String channelId,
    required String senderId,
    required Uint8List payload,
  }) async {
    if (payload.length <=
        1 + loracordAesGcmNonceBytes + loracordAesGcmMacBytes) {
      throw const FormatException('Encrypted payload is too short');
    }
    if (payload.first != loracordCryptoVersion) {
      throw FormatException('Unsupported crypto version ${payload.first}');
    }
    final nonce = payload.sublist(1, 1 + loracordAesGcmNonceBytes);
    final macStart = 1 + loracordAesGcmNonceBytes;
    final macEnd = macStart + loracordAesGcmMacBytes;
    final mac = Mac(payload.sublist(macStart, macEnd));
    final cipherText = payload.sublist(macEnd);
    final clear = await _algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(_decodeKey(key)),
      aad: utf8.encode('$messageId|$guildId|$channelId|$senderId'),
    );
    return utf8.decode(clear);
  }

  List<int> _decodeKey(String key) {
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key)) {
      return [
        for (var i = 0; i < key.length; i += 2)
          int.parse(key.substring(i, i + 2), radix: 16),
      ];
    }
    final normalized = base64Url.normalize(key);
    final bytes = base64Url.decode(normalized);
    if (bytes.length != 32) {
      throw FormatException(
        'Loracord crypto key must be 32 bytes, got ${bytes.length}',
      );
    }
    return bytes;
  }

  Future<({String privateKey, String publicKey})> newDirectIdentity() async {
    final keyPair = await _keyExchange.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return (privateKey: _hex(privateKey), publicKey: _hex(publicKey.bytes));
  }

  Future<String> publicKeyFromPrivate(String privateKey) async {
    final keyPair = await _keyExchange.newKeyPairFromSeed(
      _decodeKey(privateKey),
    );
    final publicKey = await keyPair.extractPublicKey();
    return _hex(publicKey.bytes);
  }

  Future<String> deriveDirectKey({
    required String selfId,
    required String peerId,
    required String privateKey,
    required String selfPublicKey,
    required String peerPublicKey,
  }) async {
    final keyPair = SimpleKeyPairData(
      _decodeKey(privateKey),
      publicKey: SimplePublicKey(
        _decodeKey(selfPublicKey),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final shared = await _keyExchange.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(
        _decodeKey(peerPublicKey),
        type: KeyPairType.x25519,
      ),
    );
    final sharedBytes = await shared.extractBytes();
    final ordered = _orderedIdentityMaterial(
      selfId: selfId,
      peerId: peerId,
      selfPublicKey: selfPublicKey,
      peerPublicKey: peerPublicKey,
    );
    final hash = await _hash.hash([
      ...utf8.encode('Loracord-DM-v1|$ordered|'),
      ...sharedBytes,
    ]);
    return _hex(hash.bytes);
  }

  String _orderedIdentityMaterial({
    required String selfId,
    required String peerId,
    required String selfPublicKey,
    required String peerPublicKey,
  }) {
    if (selfId.compareTo(peerId) <= 0) {
      return '$selfId:$selfPublicKey|$peerId:$peerPublicKey';
    }
    return '$peerId:$peerPublicKey|$selfId:$selfPublicKey';
  }

  String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
