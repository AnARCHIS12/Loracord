import 'dart:async';

import 'package:flutter/foundation.dart';

import 'domain/entities.dart';
import 'mesh/loracord_crypto.dart';
import 'mesh/loracord_protocol.dart';
import 'mesh/mesh_transport.dart';
import 'mesh/meshtastic_codec.dart';
import 'platform/local_notifier.dart';
import 'storage/local_storage.dart';

class LoracordController extends ChangeNotifier {
  LoracordController({
    required MeshTransport transport,
    required LocalStorage storage,
    LocalNotifier notifier = const LocalNotifier(),
    LoracordProtocol protocol = const LoracordProtocol(),
    LoracordCrypto? crypto,
    MeshtasticClientCodec? meshtasticCodec,
  }) : _transport = transport,
       _storage = storage,
       _notifier = notifier,
       _protocol = protocol,
       _crypto = crypto ?? LoracordCrypto(),
       _meshtasticCodec = meshtasticCodec ?? MeshtasticClientCodec();

  static const _stateKey = 'loracord.state.v1';

  final MeshTransport _transport;
  final LocalStorage _storage;
  final LocalNotifier _notifier;
  final LoracordProtocol _protocol;
  final LoracordCrypto _crypto;
  final MeshtasticClientCodec _meshtasticCodec;
  final LoracordReassembler _reassembler = LoracordReassembler();

  StreamSubscription<MeshTransportEvent>? _transportSub;
  LoracordState state = LoracordState.seed();
  MeshTransportStatus transportStatus = MeshTransportStatus.disconnected;
  String transportLine = 'Node not connected';
  MeshDevice? connectedDevice;
  MeshDevice? pairingDevice;
  int pairingRequestId = 0;
  List<MeshDevice> devices = const [];

  Future<void> initialize() async {
    final raw = await _storage.read(_stateKey);
    if (raw != null) {
      try {
        state = LoracordState.decode(raw);
        if (_isLegacyEmptyDemoState(state)) {
          state = _emptyStateFrom(state);
          await _save();
        }
      } catch (_) {
        state = LoracordState.seed();
      }
    }
    final beforeNormalize = state.encode();
    state = _normalizeSelection(state);
    if (state.encode() != beforeNormalize) {
      await _save();
    }
    await _ensureDirectIdentity();
    _transportSub = _transport.events.listen(_handleTransportEvent);
    notifyListeners();
  }

  String get directInviteCode {
    final publicKey = state.me.publicKey;
    if (publicKey == null || publicKey.isEmpty) return 'Generation en cours';
    return 'LDM-${state.me.id}-$publicKey';
  }

  @override
  void dispose() {
    _transportSub?.cancel();
    super.dispose();
  }

  Future<void> scanAndRequestPermissions() async {
    transportStatus = MeshTransportStatus.scanning;
    transportLine = 'Scanning for nearby BLE nodes...';
    notifyListeners();
    try {
      await _transport.requestPermissions();
      devices = await _transport.scan();
      transportStatus = devices.isEmpty
          ? MeshTransportStatus.disconnected
          : MeshTransportStatus.idle;
      transportLine = devices.isEmpty
          ? 'No BLE node found'
          : '${devices.length} BLE node(s) found';
    } catch (error) {
      devices = const [];
      transportStatus = MeshTransportStatus.error;
      transportLine = 'BLE scan failed: $error';
    }
    notifyListeners();
  }

  Future<void> connect(MeshDevice device) async {
    transportStatus = MeshTransportStatus.connecting;
    transportLine = 'Connecting to ${device.name}...';
    connectedDevice = device;
    pairingDevice = null;
    notifyListeners();
    await _transport.connect(device);
    if (transportStatus == MeshTransportStatus.connecting &&
        pairingDevice == null) {
      pairingDevice = device;
      pairingRequestId++;
      transportStatus = MeshTransportStatus.pairing;
      transportLine = 'Enter the Bluetooth PIN for ${device.name}';
      notifyListeners();
    }
  }

  Future<void> submitPairingPin(String pin) async {
    final device = pairingDevice ?? connectedDevice;
    if (device == null) return;
    transportStatus = MeshTransportStatus.connecting;
    transportLine = 'Sending Bluetooth PIN...';
    pairingDevice = null;
    notifyListeners();
    try {
      await _transport.submitPairingPin(device, pin.trim());
    } catch (error) {
      transportStatus = MeshTransportStatus.error;
      transportLine = 'Bluetooth PIN rejected: $error';
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _transport.disconnect();
    connectedDevice = null;
    pairingDevice = null;
    transportStatus = MeshTransportStatus.disconnected;
    transportLine = 'Node not connected';
    notifyListeners();
  }

  void selectGuild(String guildId) {
    final guild = state.guilds[guildId];
    if (guild == null || guild.channelIds.isEmpty) return;
    state = state.copyWith(
      selectedGuildId: guildId,
      selectedChannelId: guild.channelIds.first,
      selectedKind: ConversationKind.channel,
      clearSelectedDirectUser: true,
    );
    _save();
    notifyListeners();
  }

  void selectChannel(String channelId) {
    if (!state.channels.containsKey(channelId)) return;
    state = state.copyWith(
      selectedChannelId: channelId,
      selectedKind: ConversationKind.channel,
      clearSelectedDirectUser: true,
    );
    _save();
    notifyListeners();
  }

  void selectDirect(String userId) {
    if (userId == state.me.id || !state.users.containsKey(userId)) return;
    state = state.copyWith(
      selectedKind: ConversationKind.direct,
      selectedDirectUserId: userId,
    );
    _save();
    notifyListeners();
  }

  Future<void> addDirectContact(
    String userId,
    String name, {
    String? sharedKey,
  }) async {
    final directInvite = _parseDirectInvite(userId);
    final cleanId = directInvite?.userId ?? _normalizeDirectUserId(userId);
    if (cleanId == null || cleanId == state.me.id) {
      transportLine =
          'Invalid user ID: use LDM-..., u1234abcd, !1234abcd, or 1234abcd';
      notifyListeners();
      return;
    }
    final users = Map<String, LoraUser>.from(state.users)
      ..[cleanId] = LoraUser(
        id: cleanId,
        name: name.trim().isEmpty
            ? 'Node ${cleanId.substring(1, 5)}'
            : name.trim(),
        publicKey: directInvite?.publicKey,
      );
    final key = directInvite == null
        ? (sharedKey == null || sharedKey.trim().isEmpty
              ? null
              : sharedKey.trim())
        : await _crypto.deriveDirectKey(
            selfId: state.me.id,
            peerId: cleanId,
            privateKey: state.identityPrivateKey,
            selfPublicKey: state.me.publicKey!,
            peerPublicKey: directInvite.publicKey,
          );
    if (key != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key)) {
      transportLine = 'Invalid DM key: expected 64 hex characters';
      notifyListeners();
      return;
    }
    final directKeys = Map<String, String>.from(state.directKeys);
    if (key != null) directKeys[cleanId] = key.toLowerCase();
    state = state.copyWith(
      users: users,
      directKeys: directKeys,
      selectedKind: ConversationKind.direct,
      selectedDirectUserId: cleanId,
    );
    await _save();
    if (directInvite != null) {
      transportLine = 'DM key derived automatically with X25519';
    } else if (key == null) {
      transportLine = 'Native Meshtastic DM enabled for $cleanId';
    }
    notifyListeners();
  }

  Future<void> createGuild(String name) async {
    final guildId = newMeshId('g');
    final general = newMeshId('c');
    final ops = newMeshId('c');
    final cryptoKey = newCryptoKey();
    final guild = LoraGuild(
      id: guildId,
      name: name.trim().isEmpty ? 'New server' : name.trim(),
      inviteKey: 'LC2-$guildId-$cryptoKey',
      channelIds: [general, ops],
      cryptoKey: cryptoKey,
    );
    final guilds = Map<String, LoraGuild>.from(state.guilds)
      ..[guild.id] = guild;
    final channels = Map<String, LoraChannel>.from(state.channels)
      ..[general] = LoraChannel(id: general, guildId: guild.id, name: 'general')
      ..[ops] = LoraChannel(id: ops, guildId: guild.id, name: 'ops');
    state = state.copyWith(
      guilds: guilds,
      channels: channels,
      selectedGuildId: guild.id,
      selectedChannelId: general,
      selectedKind: ConversationKind.channel,
      clearSelectedDirectUser: true,
    );
    await _save();
    notifyListeners();
  }

  Future<void> createChannel(String name) async {
    final guild = state.selectedGuildOrNull;
    if (guild == null) {
      transportLine = 'Create or join a server before creating a channel';
      notifyListeners();
      return;
    }
    final cleanName = _normalizeChannelName(name);
    if (cleanName.isEmpty) {
      transportLine = 'Invalid channel name';
      notifyListeners();
      return;
    }
    final channelId = newMeshId('c');
    final channel = LoraChannel(
      id: channelId,
      guildId: guild.id,
      name: cleanName,
    );
    final guilds = Map<String, LoraGuild>.from(state.guilds)
      ..[guild.id] = guild.copyWith(
        channelIds: [...guild.channelIds, channelId],
      );
    final channels = Map<String, LoraChannel>.from(state.channels)
      ..[channelId] = channel;
    state = state.copyWith(
      guilds: guilds,
      channels: channels,
      selectedKind: ConversationKind.channel,
      selectedChannelId: channelId,
      clearSelectedDirectUser: true,
    );
    await _save();
    notifyListeners();
  }

  Future<void> joinInvite(String inviteCode) async {
    final parts = inviteCode.trim().split('-');
    if (parts.length < 3 || (parts.first != 'LC' && parts.first != 'LC2')) {
      return;
    }
    final guildId = parts[1];
    if (state.guilds.containsKey(guildId)) {
      selectGuild(guildId);
      return;
    }
    final cryptoKey = parts.first == 'LC2' && parts.length >= 3
        ? parts[2]
        : newCryptoKey();
    final channelId = newMeshId('c');
    final guild = LoraGuild(
      id: guildId,
      name: 'Server $guildId',
      inviteKey: inviteCode.trim(),
      channelIds: [channelId],
      cryptoKey: cryptoKey,
    );
    final guilds = Map<String, LoraGuild>.from(state.guilds)
      ..[guild.id] = guild;
    final channels = Map<String, LoraChannel>.from(state.channels)
      ..[channelId] = LoraChannel(
        id: channelId,
        guildId: guild.id,
        name: 'general',
      );
    state = state.copyWith(
      guilds: guilds,
      channels: channels,
      selectedGuildId: guild.id,
      selectedChannelId: channelId,
      selectedKind: ConversationKind.channel,
      clearSelectedDirectUser: true,
    );
    await _save();
    notifyListeners();
  }

  Future<void> sendText(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (transportStatus != MeshTransportStatus.connected) {
      transportLine = 'Connect a Meshtastic node before sending';
      notifyListeners();
      return;
    }
    if (!state.isDirectSelected && !state.hasSelectedChannel) {
      transportLine = 'Create or join a server before sending';
      notifyListeners();
      return;
    }

    final message = LoraMessage(
      id: newMeshId('m'),
      guildId: state.isDirectSelected ? 'g00000000' : state.selectedGuildId,
      channelId: state.isDirectSelected
          ? state.selectedDirectUserId!
          : state.selectedChannelId,
      senderId: state.me.id,
      body: clean,
      createdAt: DateTime.now(),
      status: MessageStatus.pending,
      fragmentCount: 1,
      isDirect: state.isDirectSelected,
      recipientId: state.isDirectSelected ? state.selectedDirectUserId : null,
    );
    state = state.copyWith(messages: [...state.messages, message]);
    await _save();
    notifyListeners();

    try {
      final frames = await _sendMessageFrames(message);
      _replaceMessage(
        message.id,
        message.copyWith(
          status: MessageStatus.sent,
          fragmentCount: frames.length,
        ),
      );
      transportLine = '${frames.length} fragment(s) sent to the node';
    } catch (error) {
      _replaceMessage(
        message.id,
        message.copyWith(status: MessageStatus.failed),
      );
      transportLine = 'Send failed: $error';
    }
    await _save();
    notifyListeners();
  }

  Future<void> requestHistorySync() async {
    if (transportStatus != MeshTransportStatus.connected) {
      transportLine = 'Connect a Meshtastic node before sync';
      notifyListeners();
      return;
    }
    if (!state.isDirectSelected && !state.hasSelectedChannel) {
      transportLine = 'No channel to sync';
      notifyListeners();
      return;
    }
    final direct = state.isDirectSelected;
    final channelId = direct
        ? state.selectedDirectUserId!
        : state.selectedChannelId;
    final guildId = direct ? 'g00000000' : state.selectedGuildId;
    final existing = state.messagesForCurrentConversation().toList();
    final since = existing.isEmpty
        ? DateTime.now().subtract(const Duration(days: 7))
        : existing.last.createdAt.subtract(const Duration(minutes: 1));
    final frames = _protocol.syncRequest(
      messageId: newMeshId('m'),
      guildId: guildId,
      channelId: channelId,
      senderId: state.me.id,
      since: since,
      direct: direct,
    );
    final directTo = direct ? _nodeNumFromUserId(channelId) : null;
    for (final frame in frames) {
      await _transport.write(
        _meshtasticCodec.encodePrivateAppPacket(
          frame,
          to: directTo ?? meshtasticBroadcast,
        ),
      );
    }
    transportLine = 'History catch-up request sent';
    notifyListeners();
  }

  void _handleTransportEvent(MeshTransportEvent event) {
    if (event.data != null) {
      _handleIncomingBytes(event.data!);
      return;
    }
    if (event.status == MeshTransportStatus.pairing && event.device != null) {
      pairingDevice = event.device;
      connectedDevice = event.device;
      pairingRequestId++;
      transportStatus = MeshTransportStatus.pairing;
      transportLine = event.message ?? 'Bluetooth PIN required';
      notifyListeners();
      return;
    }
    transportStatus = event.status;
    if (event.status == MeshTransportStatus.connected) {
      pairingDevice = null;
      transportLine = event.message ?? 'Meshtastic node connected';
      unawaited(_requestMeshtasticConfig());
    } else if (event.status == MeshTransportStatus.disconnected) {
      connectedDevice = null;
      pairingDevice = null;
      transportLine = event.message ?? 'Node disconnected';
    } else if (event.status == MeshTransportStatus.error) {
      transportLine = event.message ?? 'Transport error';
    }
    notifyListeners();
  }

  void _handleIncomingBytes(Uint8List bytes) {
    final myNodeNum = _meshtasticCodec.tryDecodeMyNodeNum(bytes);
    if (myNodeNum != null) {
      unawaited(_adoptMeshtasticNodeId(myNodeNum));
    }

    final privatePacket = _meshtasticCodec.tryDecodePrivateAppPacket(bytes);
    if (privatePacket == null) return;
    final frame = LoracordFrame.tryDecode(privatePacket.payload);
    if (frame == null) return;
    final packet = _reassembler.accept(frame);
    if (packet == null) return;
    unawaited(_handleIncomingPacket(packet, meshFrom: privatePacket.from));
  }

  Future<void> _handleIncomingPacket(
    ReassembledLoracordMessage packet, {
    int? meshFrom,
  }) async {
    if (packet.type == LoracordFrameType.syncRequest) {
      await _handleSyncRequest(packet);
      return;
    }
    if (state.messages.any((message) => message.id == packet.messageId)) return;
    final meshSenderId = meshFrom == null ? null : _userIdFromNodeNum(meshFrom);
    final effectiveSenderId = packet.type == LoracordFrameType.directText
        ? meshSenderId ?? packet.senderId
        : packet.senderId;
    if (packet.type == LoracordFrameType.directText &&
        packet.channelId != state.me.id &&
        packet.senderId != state.me.id &&
        meshSenderId == null) {
      return;
    }
    final body = await _decodePacketBody(packet);
    if (body == null) return;

    final users = Map<String, LoraUser>.from(state.users);
    users.putIfAbsent(
      effectiveSenderId,
      () => LoraUser(
        id: effectiveSenderId,
        name: 'Node ${effectiveSenderId.substring(1, 5)}',
      ),
    );
    final message = LoraMessage(
      id: packet.messageId,
      guildId: packet.guildId,
      channelId: packet.channelId,
      senderId: effectiveSenderId,
      body: body,
      createdAt: packet.createdAt,
      status: MessageStatus.received,
      fragmentCount: packet.fragmentCount,
      isDirect: packet.type == LoracordFrameType.directText,
      recipientId: packet.type == LoracordFrameType.directText
          ? (packet.senderId == state.me.id ? packet.channelId : state.me.id)
          : null,
    );
    state = state.copyWith(
      users: users,
      messages: [...state.messages, message],
    );
    _save();
    _notifier.notifyMessage(title: users[effectiveSenderId]!.name, body: body);
    notifyListeners();
  }

  Future<List<Uint8List>> _sendMessageFrames(LoraMessage message) async {
    final key = _keyForOutgoingMessage(message);
    final encryptedPayload = key == null
        ? null
        : await _crypto.encryptText(
            key: key,
            messageId: message.id,
            guildId: message.guildId,
            channelId: message.channelId,
            senderId: message.senderId,
            text: message.body,
          );
    final frames = encryptedPayload == null
        ? _protocol.fragmentText(
            type: message.isDirect
                ? LoracordFrameType.directText
                : LoracordFrameType.channelText,
            messageId: message.id,
            guildId: message.guildId,
            channelId: message.channelId,
            senderId: message.senderId,
            createdAt: message.createdAt,
            text: message.body,
          )
        : _protocol.fragmentBytes(
            type: message.isDirect
                ? LoracordFrameType.directText
                : LoracordFrameType.channelText,
            messageId: message.id,
            guildId: message.guildId,
            channelId: message.channelId,
            senderId: message.senderId,
            createdAt: message.createdAt,
            payload: encryptedPayload,
            encrypted: true,
          );
    final directTo = message.isDirect && message.recipientId != null
        ? _nodeNumFromUserId(message.recipientId!)
        : null;
    for (final frame in frames) {
      await _transport.write(
        _meshtasticCodec.encodePrivateAppPacket(
          frame,
          to: directTo ?? meshtasticBroadcast,
        ),
      );
    }
    return frames;
  }

  Future<String?> _decodePacketBody(ReassembledLoracordMessage packet) async {
    if (!packet.encrypted) return packet.text;
    final key = _keyForIncomingPacket(packet);
    if (key == null) {
      transportLine = 'Encrypted message ignored: missing server key';
      notifyListeners();
      return null;
    }
    try {
      return await _crypto.decryptText(
        key: key,
        messageId: packet.messageId,
        guildId: packet.guildId,
        channelId: packet.channelId,
        senderId: packet.senderId,
        payload: packet.payload,
      );
    } catch (_) {
      transportLine = 'Encrypted message ignored: invalid key';
      notifyListeners();
      return null;
    }
  }

  String? _keyForOutgoingMessage(LoraMessage message) {
    if (message.isDirect) {
      final recipient = message.recipientId;
      return recipient == null ? null : state.directKeys[recipient];
    }
    return state.guilds[message.guildId]?.cryptoKey;
  }

  String? _keyForIncomingPacket(ReassembledLoracordMessage packet) {
    if (packet.type == LoracordFrameType.directText) {
      final peerId = packet.senderId == state.me.id
          ? packet.channelId
          : packet.senderId;
      return state.directKeys[peerId];
    }
    return state.guilds[packet.guildId]?.cryptoKey;
  }

  Future<void> _handleSyncRequest(ReassembledLoracordMessage packet) async {
    if (packet.senderId == state.me.id) return;
    final request = LoracordSyncRequest.tryParse(packet.text);
    if (request == null) return;
    final candidates = state.messages
        .where((message) {
          if (!message.createdAt.isAfter(request.since)) return false;
          if (request.direct) {
            return message.isDirect &&
                ((message.senderId == packet.senderId &&
                        message.recipientId == packet.channelId) ||
                    (message.senderId == packet.channelId &&
                        message.recipientId == packet.senderId));
          }
          return !message.isDirect &&
              message.guildId == packet.guildId &&
              message.channelId == packet.channelId;
        })
        .take(6)
        .toList();

    for (final message in candidates) {
      await _sendMessageFrames(message);
    }
    transportLine = 'Sync: ${candidates.length} message(s) offered to the mesh';
    notifyListeners();
  }

  void _replaceMessage(String id, LoraMessage replacement) {
    state = state.copyWith(
      messages: state.messages
          .map((message) => message.id == id ? replacement : message)
          .toList(),
    );
  }

  Future<void> _requestMeshtasticConfig() async {
    try {
      await _transport.write(_meshtasticCodec.encodeWantConfig());
    } catch (_) {
      // The node may already be busy; normal messaging can still work.
    }
  }

  Future<void> _adoptMeshtasticNodeId(int nodeNum) async {
    final nodeUserId = _userIdFromNodeNum(nodeNum);
    if (nodeUserId == state.me.id) return;
    final oldId = state.me.id;
    final me = state.me.copyWith(id: nodeUserId);
    final users = Map<String, LoraUser>.from(state.users)
      ..remove(oldId)
      ..[nodeUserId] = me;
    state = state.copyWith(me: me, users: users);
    await _save();
    notifyListeners();
  }

  int? _nodeNumFromUserId(String userId) {
    final clean = _normalizeDirectUserId(userId);
    if (clean == null) return null;
    return int.tryParse(clean.substring(1), radix: 16);
  }

  String _userIdFromNodeNum(int nodeNum) {
    final hex = (nodeNum & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return 'u$hex';
  }

  Future<void> _save() => _storage.write(_stateKey, state.encode());

  bool _isLegacyEmptyDemoState(LoracordState value) {
    if (value.messages.isNotEmpty) return false;
    if (value.guilds.length != 1 || !value.guilds.containsKey('g7a01cafe')) {
      return false;
    }
    final guild = value.guilds['g7a01cafe']!;
    return guild.name == 'Camp Mesh' &&
        value.channels.values.every((channel) => channel.guildId == guild.id);
  }

  LoracordState _emptyStateFrom(LoracordState value) {
    return value.copyWith(
      guilds: const {},
      channels: const {},
      selectedGuildId: '',
      selectedChannelId: '',
      selectedKind: ConversationKind.channel,
      clearSelectedDirectUser: true,
    );
  }

  LoracordState _normalizeSelection(LoracordState value) {
    if (value.guilds.isEmpty) {
      if (value.selectedGuildId.isEmpty &&
          value.selectedChannelId.isEmpty &&
          !value.isDirectSelected) {
        return value;
      }
      return value.copyWith(
        selectedGuildId: '',
        selectedChannelId: '',
        selectedKind: ConversationKind.channel,
        clearSelectedDirectUser: true,
      );
    }
    final selectedDirect = value.selectedDirectUserId;
    if (value.selectedKind == ConversationKind.direct &&
        selectedDirect != null &&
        value.users.containsKey(selectedDirect)) {
      return value;
    }
    final guild =
        value.guilds[value.selectedGuildId] ?? value.guilds.values.first;
    final channelId = guild.channelIds.firstWhere(
      value.channels.containsKey,
      orElse: () => '',
    );
    if (channelId.isEmpty) {
      final fallbackChannelId = newMeshId('c');
      final guilds = Map<String, LoraGuild>.from(value.guilds)
        ..[guild.id] = guild.copyWith(channelIds: [fallbackChannelId]);
      final channels = Map<String, LoraChannel>.from(value.channels)
        ..[fallbackChannelId] = LoraChannel(
          id: fallbackChannelId,
          guildId: guild.id,
          name: 'general',
        );
      return value.copyWith(
        guilds: guilds,
        channels: channels,
        selectedGuildId: guild.id,
        selectedChannelId: fallbackChannelId,
        selectedKind: ConversationKind.channel,
        clearSelectedDirectUser: true,
      );
    }
    return value.copyWith(
      selectedGuildId: guild.id,
      selectedChannelId: channelId,
      selectedKind: ConversationKind.channel,
      clearSelectedDirectUser: true,
    );
  }

  Future<void> _ensureDirectIdentity() async {
    var privateKey = state.identityPrivateKey;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(privateKey)) {
      privateKey = newCryptoKey();
    }
    final publicKey = await _crypto.publicKeyFromPrivate(privateKey);
    if (state.identityPrivateKey == privateKey &&
        state.me.publicKey == publicKey) {
      return;
    }
    final me = state.me.copyWith(publicKey: publicKey);
    final users = Map<String, LoraUser>.from(state.users)..[me.id] = me;
    state = state.copyWith(
      me: me,
      users: users,
      identityPrivateKey: privateKey,
    );
    await _save();
  }

  ({String userId, String publicKey})? _parseDirectInvite(String value) {
    final parts = value.trim().split('-');
    if (parts.length != 3 || parts.first != 'LDM') return null;
    final userId = parts[1];
    final publicKey = parts[2];
    final validUser =
        userId.startsWith('u') &&
        userId.length == 9 &&
        int.tryParse(userId.substring(1), radix: 16) != null;
    final validKey = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey);
    if (!validUser || !validKey) return null;
    return (userId: userId, publicKey: publicKey.toLowerCase());
  }

  String? _normalizeDirectUserId(String value) {
    final clean = value.trim().toLowerCase();
    if (RegExp(r'^u[0-9a-f]{8}$').hasMatch(clean)) return clean;
    if (RegExp(r'^[0-9a-f]{8}$').hasMatch(clean)) return 'u$clean';
    if (RegExp(r'^![0-9a-f]{8}$').hasMatch(clean)) {
      return 'u${clean.substring(1)}';
    }
    return null;
  }

  String _normalizeChannelName(String value) {
    final clean = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return clean.length > 24 ? clean.substring(0, 24) : clean;
  }
}
