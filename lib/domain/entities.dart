import 'dart:convert';
import 'dart:math';

enum MessageStatus { pending, sent, received, failed }

enum ConversationKind { channel, direct }

String newMeshId([String prefix = '']) {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rnd = Random.secure().nextInt(0x7fffffff);
  final raw = (now ^ rnd) & 0xffffffff;
  return '$prefix${raw.toRadixString(16).padLeft(8, '0')}';
}

String newCryptoKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class LoraUser {
  const LoraUser({required this.id, required this.name, this.publicKey});

  final String id;
  final String name;
  final String? publicKey;

  String get shortName {
    final clean = name.trim();
    if (clean.isEmpty) return '??';
    return String.fromCharCodes(clean.runes.take(2)).toUpperCase();
  }

  LoraUser copyWith({String? id, String? name, String? publicKey}) => LoraUser(
    id: id ?? this.id,
    name: name ?? this.name,
    publicKey: publicKey ?? this.publicKey,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'publicKey': publicKey,
  };

  factory LoraUser.fromJson(Map<String, Object?> json) => LoraUser(
    id: json['id'] as String,
    name: json['name'] as String,
    publicKey: json['publicKey'] as String?,
  );
}

class LoraGuild {
  const LoraGuild({
    required this.id,
    required this.name,
    required this.inviteKey,
    required this.channelIds,
    required this.cryptoKey,
  });

  final String id;
  final String name;
  final String inviteKey;
  final List<String> channelIds;
  final String cryptoKey;

  LoraGuild copyWith({
    String? id,
    String? name,
    String? inviteKey,
    List<String>? channelIds,
    String? cryptoKey,
  }) {
    return LoraGuild(
      id: id ?? this.id,
      name: name ?? this.name,
      inviteKey: inviteKey ?? this.inviteKey,
      channelIds: channelIds ?? this.channelIds,
      cryptoKey: cryptoKey ?? this.cryptoKey,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'inviteKey': inviteKey,
    'channelIds': channelIds,
    'cryptoKey': cryptoKey,
  };

  factory LoraGuild.fromJson(Map<String, Object?> json) => LoraGuild(
    id: json['id'] as String,
    name: json['name'] as String,
    inviteKey: json['inviteKey'] as String,
    channelIds: (json['channelIds'] as List<Object?>).cast<String>(),
    cryptoKey: json['cryptoKey'] as String? ?? newCryptoKey(),
  );
}

class LoraChannel {
  const LoraChannel({
    required this.id,
    required this.guildId,
    required this.name,
  });

  final String id;
  final String guildId;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'guildId': guildId, 'name': name};

  factory LoraChannel.fromJson(Map<String, Object?> json) => LoraChannel(
    id: json['id'] as String,
    guildId: json['guildId'] as String,
    name: json['name'] as String,
  );
}

class LoraMessage {
  const LoraMessage({
    required this.id,
    required this.guildId,
    required this.channelId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    required this.status,
    required this.fragmentCount,
    this.isDirect = false,
    this.recipientId,
  });

  final String id;
  final String guildId;
  final String channelId;
  final String senderId;
  final String body;
  final DateTime createdAt;
  final MessageStatus status;
  final int fragmentCount;
  final bool isDirect;
  final String? recipientId;

  LoraMessage copyWith({MessageStatus? status, int? fragmentCount}) {
    return LoraMessage(
      id: id,
      guildId: guildId,
      channelId: channelId,
      senderId: senderId,
      body: body,
      createdAt: createdAt,
      status: status ?? this.status,
      fragmentCount: fragmentCount ?? this.fragmentCount,
      isDirect: isDirect,
      recipientId: recipientId,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'guildId': guildId,
    'channelId': channelId,
    'senderId': senderId,
    'body': body,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'fragmentCount': fragmentCount,
    'isDirect': isDirect,
    'recipientId': recipientId,
  };

  factory LoraMessage.fromJson(Map<String, Object?> json) => LoraMessage(
    id: json['id'] as String,
    guildId: json['guildId'] as String,
    channelId: json['channelId'] as String,
    senderId: json['senderId'] as String,
    body: json['body'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: MessageStatus.values.byName(json['status'] as String),
    fragmentCount: json['fragmentCount'] as int,
    isDirect: json['isDirect'] as bool? ?? false,
    recipientId: json['recipientId'] as String?,
  );
}

class LoracordState {
  const LoracordState({
    required this.me,
    required this.users,
    required this.guilds,
    required this.channels,
    required this.directKeys,
    required this.identityPrivateKey,
    required this.messages,
    required this.selectedGuildId,
    required this.selectedChannelId,
    required this.selectedKind,
    this.selectedDirectUserId,
  });

  final LoraUser me;
  final Map<String, LoraUser> users;
  final Map<String, LoraGuild> guilds;
  final Map<String, LoraChannel> channels;
  final Map<String, String> directKeys;
  final String identityPrivateKey;
  final List<LoraMessage> messages;
  final String selectedGuildId;
  final String selectedChannelId;
  final ConversationKind selectedKind;
  final String? selectedDirectUserId;

  LoraGuild get selectedGuild => guilds[selectedGuildId]!;
  LoraChannel get selectedChannel => channels[selectedChannelId]!;
  LoraGuild? get selectedGuildOrNull => guilds[selectedGuildId];
  LoraChannel? get selectedChannelOrNull => channels[selectedChannelId];
  LoraUser? get selectedDirectUser => users[selectedDirectUserId];
  bool get hasGuilds => guilds.isNotEmpty;
  bool get hasSelectedChannel => selectedChannelOrNull != null;

  bool get isDirectSelected =>
      selectedKind == ConversationKind.direct && selectedDirectUserId != null;

  Iterable<LoraMessage> messagesForSelectedChannel() =>
      messages
          .where(
            (m) =>
                m.guildId == selectedGuildId &&
                m.channelId == selectedChannelId,
          )
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Iterable<LoraMessage> messagesForSelectedDirect() {
    final peerId = selectedDirectUserId;
    if (peerId == null) return const [];
    return messages
        .where(
          (m) =>
              m.isDirect &&
              ((m.senderId == me.id && m.recipientId == peerId) ||
                  (m.senderId == peerId && m.recipientId == me.id)),
        )
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Iterable<LoraMessage> messagesForCurrentConversation() => isDirectSelected
      ? messagesForSelectedDirect()
      : !hasSelectedChannel
      ? const []
      : messagesForSelectedChannel();

  Iterable<LoraUser> directPeers() {
    final ids = <String>{};
    for (final message in messages.where((m) => m.isDirect)) {
      if (message.senderId != me.id) ids.add(message.senderId);
      final recipient = message.recipientId;
      if (recipient != null && recipient != me.id) ids.add(recipient);
    }
    ids.addAll(users.keys.where((id) => id != me.id));
    return ids.map((id) => users[id]).whereType<LoraUser>();
  }

  LoracordState copyWith({
    LoraUser? me,
    Map<String, LoraUser>? users,
    Map<String, LoraGuild>? guilds,
    Map<String, LoraChannel>? channels,
    Map<String, String>? directKeys,
    String? identityPrivateKey,
    List<LoraMessage>? messages,
    String? selectedGuildId,
    String? selectedChannelId,
    ConversationKind? selectedKind,
    String? selectedDirectUserId,
    bool clearSelectedDirectUser = false,
  }) {
    return LoracordState(
      me: me ?? this.me,
      users: users ?? this.users,
      guilds: guilds ?? this.guilds,
      channels: channels ?? this.channels,
      directKeys: directKeys ?? this.directKeys,
      identityPrivateKey: identityPrivateKey ?? this.identityPrivateKey,
      messages: messages ?? this.messages,
      selectedGuildId: selectedGuildId ?? this.selectedGuildId,
      selectedChannelId: selectedChannelId ?? this.selectedChannelId,
      selectedKind: selectedKind ?? this.selectedKind,
      selectedDirectUserId: clearSelectedDirectUser
          ? null
          : selectedDirectUserId ?? this.selectedDirectUserId,
    );
  }

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {
    'me': me.toJson(),
    'users': users.map((key, value) => MapEntry(key, value.toJson())),
    'guilds': guilds.map((key, value) => MapEntry(key, value.toJson())),
    'channels': channels.map((key, value) => MapEntry(key, value.toJson())),
    'directKeys': directKeys,
    'identityPrivateKey': identityPrivateKey,
    'messages': messages.map((m) => m.toJson()).toList(),
    'selectedGuildId': selectedGuildId,
    'selectedChannelId': selectedChannelId,
    'selectedKind': selectedKind.name,
    'selectedDirectUserId': selectedDirectUserId,
  };

  factory LoracordState.decode(String raw) {
    final json = jsonDecode(raw) as Map<String, Object?>;
    return LoracordState(
      me: LoraUser.fromJson((json['me'] as Map<Object?, Object?>).cast()),
      users: ((json['users'] as Map<Object?, Object?>).cast<String, Object?>())
          .map(
            (key, value) => MapEntry(
              key,
              LoraUser.fromJson((value as Map<Object?, Object?>).cast()),
            ),
          ),
      guilds:
          ((json['guilds'] as Map<Object?, Object?>).cast<String, Object?>())
              .map(
                (key, value) => MapEntry(
                  key,
                  LoraGuild.fromJson((value as Map<Object?, Object?>).cast()),
                ),
              ),
      channels:
          ((json['channels'] as Map<Object?, Object?>).cast<String, Object?>())
              .map(
                (key, value) => MapEntry(
                  key,
                  LoraChannel.fromJson((value as Map<Object?, Object?>).cast()),
                ),
              ),
      directKeys:
          ((json['directKeys'] as Map<Object?, Object?>?)
                  ?.cast<String, Object?>())
              ?.map((key, value) => MapEntry(key, value as String)) ??
          const {},
      identityPrivateKey:
          json['identityPrivateKey'] as String? ?? newCryptoKey(),
      messages: (json['messages'] as List<Object?>)
          .map(
            (value) =>
                LoraMessage.fromJson((value as Map<Object?, Object?>).cast()),
          )
          .toList(),
      selectedGuildId: json['selectedGuildId'] as String,
      selectedChannelId: json['selectedChannelId'] as String,
      selectedKind: ConversationKind.values.byName(
        json['selectedKind'] as String? ?? ConversationKind.channel.name,
      ),
      selectedDirectUserId: json['selectedDirectUserId'] as String?,
    );
  }

  factory LoracordState.seed() {
    final identityPrivateKey = newCryptoKey();
    final me = LoraUser(id: newMeshId('u'), name: 'Nomad');
    return LoracordState(
      me: me,
      users: {me.id: me},
      guilds: const {},
      channels: const {},
      directKeys: const {},
      identityPrivateKey: identityPrivateKey,
      messages: const [],
      selectedGuildId: '',
      selectedChannelId: '',
      selectedKind: ConversationKind.channel,
    );
  }
}
