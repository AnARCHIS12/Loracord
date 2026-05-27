import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'domain/entities.dart';
import 'mesh/mesh_transport.dart';
import 'mesh/meshtastic_ble_transport.dart';
import 'storage/local_storage.dart';
import 'ui/loracord_logo.dart';

class LoracordApp extends StatefulWidget {
  const LoracordApp({super.key});

  @override
  State<LoracordApp> createState() => _LoracordAppState();
}

class _LoracordAppState extends State<LoracordApp> {
  late final LoracordController controller;

  @override
  void initState() {
    super.initState();
    controller = LoracordController(
      transport: MeshtasticBleTransport(),
      storage: const NativeLocalStorage(),
    )..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Loracord',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff15a06d),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff17191f),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => HomeScreen(controller: controller),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final LoracordController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _message = TextEditingController();
  int _shownPairingRequestId = 0;
  bool _mobileConversationOpen = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pairingDevice = widget.controller.pairingDevice;
    if (pairingDevice != null &&
        widget.controller.pairingRequestId != _shownPairingRequestId) {
      _shownPairingRequestId = widget.controller.pairingRequestId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPairingPin(context, widget.controller, pairingDevice);
      });
    }
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!widget.controller.state.hasGuilds) {
              return _FirstRunView(controller: widget.controller);
            }
            final compact = constraints.maxWidth < 720;
            if (compact) {
              if (_mobileConversationOpen) {
                return _ConversationView(
                  controller: widget.controller,
                  textController: _message,
                  onBack: () => setState(() => _mobileConversationOpen = false),
                );
              }
              return Row(
                children: [
                  _GuildRail(controller: widget.controller),
                  Expanded(
                    child: _ChannelPane(
                      controller: widget.controller,
                      onConversationSelected: () =>
                          setState(() => _mobileConversationOpen = true),
                    ),
                  ),
                ],
              );
            }
            return Row(
              children: [
                _GuildRail(controller: widget.controller),
                _ChannelPane(controller: widget.controller),
                Expanded(
                  child: _ConversationView(
                    controller: widget.controller,
                    textController: _message,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FirstRunView extends StatelessWidget {
  const _FirstRunView({required this.controller});

  final LoracordController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xff17191f),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: LoracordLogo(size: 68),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Bienvenue sur Loracord',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Configure ton premier espace mesh: cree un serveur local ou rejoins une communaute avec un code LC2.',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white70,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => _showCreateGuild(context, controller),
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Creer mon serveur'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => _showJoinInvite(context, controller),
                        icon: const Icon(Icons.key),
                        label: const Text('Rejoindre avec invitation'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => _showDevices(context, controller),
                        icon: const Icon(Icons.bluetooth_searching),
                        label: const Text('Connecter le module Meshtastic'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(top: false, child: _NodeStatus(controller: controller)),
        ],
      ),
    );
  }
}

class _ConversationView extends StatelessWidget {
  const _ConversationView({
    required this.controller,
    required this.textController,
    this.onBack,
  });

  final LoracordController controller;
  final TextEditingController textController;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(controller: controller, onBack: onBack),
        Expanded(child: _MessageList(state: controller.state)),
        _Composer(controller: controller, textController: textController),
      ],
    );
  }
}

class _GuildRail extends StatelessWidget {
  const _GuildRail({required this.controller});

  final LoracordController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Container(
      width: 68,
      color: const Color(0xff101217),
      child: Column(
        children: [
          const SizedBox(height: 10),
          const Tooltip(message: 'Loracord', child: LoracordLogo(size: 48)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final guild in state.guilds.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Tooltip(
                      message: guild.name,
                      child: IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: guild.id == state.selectedGuildId
                              ? Theme.of(context).colorScheme.primary
                              : const Color(0xff242833),
                          fixedSize: const Size(46, 46),
                        ),
                        onPressed: () => controller.selectGuild(guild.id),
                        icon: Text(
                          guild.name.substring(0, 1).toUpperCase(),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Creer un serveur',
            onPressed: () => _showCreateGuild(context, controller),
            icon: const Icon(Icons.add_circle_outline),
          ),
          IconButton(
            tooltip: 'Rejoindre avec invitation',
            onPressed: () => _showJoinInvite(context, controller),
            icon: const Icon(Icons.key),
          ),
          IconButton(
            tooltip: 'Ajouter un DM',
            onPressed: () => _showAddDirectContact(context, controller),
            icon: const Icon(Icons.person_add_alt_1),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ChannelPane extends StatelessWidget {
  const _ChannelPane({required this.controller, this.onConversationSelected});

  final LoracordController controller;
  final VoidCallback? onConversationSelected;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final guild = state.selectedGuild;
    return Container(
      width: onConversationSelected == null ? 214 : null,
      color: const Color(0xff1d2028),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 12, 12),
            child: Row(
              children: [
                const LoracordLogo(size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    guild.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SelectableText(
              guild.inviteKey,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white60),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'SALONS TEXTE',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Creer un salon',
                        onPressed: () =>
                            _showCreateChannel(context, controller),
                        icon: const Icon(Icons.add, size: 18),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                for (final id in guild.channelIds)
                  _ChannelTile(
                    channel: state.channels[id]!,
                    selected:
                        state.selectedKind == ConversationKind.channel &&
                        id == state.selectedChannelId,
                    onTap: () {
                      controller.selectChannel(id);
                      onConversationSelected?.call();
                    },
                  ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'MESSAGES PRIVES',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Ajouter un DM',
                        onPressed: () =>
                            _showAddDirectContact(context, controller),
                        icon: const Icon(Icons.add, size: 18),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                for (final user in state.directPeers())
                  _DirectTile(
                    user: user,
                    selected:
                        state.selectedKind == ConversationKind.direct &&
                        state.selectedDirectUserId == user.id,
                    onTap: () {
                      controller.selectDirect(user.id);
                      onConversationSelected?.call();
                    },
                  ),
              ],
            ),
          ),
          _NodeStatus(controller: controller),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final LoraChannel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: const Color(0xff2b303c),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: const Icon(Icons.tag, size: 18),
        title: Text(channel.name, overflow: TextOverflow.ellipsis),
        onTap: onTap,
      ),
    );
  }
}

class _DirectTile extends StatelessWidget {
  const _DirectTile({
    required this.user,
    required this.selected,
    required this.onTap,
  });

  final LoraUser user;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: const Color(0xff2b303c),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: CircleAvatar(
          radius: 12,
          backgroundColor: const Color(0xff343b49),
          child: Text(user.shortName, style: const TextStyle(fontSize: 9)),
        ),
        title: Text(user.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          user.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        onTap: onTap,
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, this.onBack});

  final LoracordController controller;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final directUser = state.selectedDirectUser;
    final isDirect = state.isDirectSelected && directUser != null;
    final title = isDirect ? directUser.name : state.selectedChannel.name;
    final icon = isDirect ? Icons.alternate_email : Icons.tag;
    return Container(
      height: 58,
      decoration: const BoxDecoration(
        color: Color(0xff20242d),
        border: Border(bottom: BorderSide(color: Color(0xff2c313d))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              tooltip: 'Retour salons',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 4),
          ],
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: 'Rattraper historique',
            onPressed:
                controller.transportStatus == MeshTransportStatus.connected
                ? controller.requestHistorySync
                : null,
            icon: const Icon(Icons.sync, size: 20),
          ),
          Text(
            '${state.messagesForCurrentConversation().length} msgs',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white60),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.state});

  final LoracordState state;

  @override
  Widget build(BuildContext context) {
    final messages = state.messagesForCurrentConversation().toList();
    if (messages.isEmpty) {
      return Center(
        child: Text(
          state.isDirectSelected
              ? 'Aucun message prive dans cette conversation.'
              : 'Aucun message recu sur ce salon.',
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final user =
            state.users[message.senderId] ??
            LoraUser(id: message.senderId, name: message.senderId);
        return _MessageRow(
          message: message,
          user: user,
          mine: message.senderId == state.me.id,
        );
      },
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.user,
    required this.mine,
  });

  final LoraMessage message;
  final LoraUser user;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final status = switch (message.status) {
      MessageStatus.pending => 'en attente',
      MessageStatus.sent => 'envoye',
      MessageStatus.received => '${message.fragmentCount} frag',
      MessageStatus.failed => 'echec',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: mine
                ? Theme.of(context).colorScheme.primary
                : const Color(0xff343b49),
            child: Text(
              user.shortName,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      user.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      status,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                SelectableText(message.body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.textController});

  final LoracordController controller;
  final TextEditingController textController;

  @override
  Widget build(BuildContext context) {
    final connected =
        controller.transportStatus == MeshTransportStatus.connected;
    final direct = controller.state.isDirectSelected;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      color: const Color(0xff17191f),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: textController,
              minLines: 1,
              maxLines: 3,
              maxLength: 420,
              enabled: connected,
              decoration: InputDecoration(
                counterText: '',
                hintText: connected
                    ? (direct ? 'DM court via LoRa' : 'Message court via LoRa')
                    : 'Connecte un module Meshtastic',
                filled: true,
                fillColor: const Color(0xff232833),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            tooltip: 'Envoyer',
            onPressed: connected ? _send : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  void _send() {
    final value = textController.text;
    textController.clear();
    controller.sendText(value);
  }
}

class _NodeStatus extends StatelessWidget {
  const _NodeStatus({required this.controller});

  final LoracordController controller;

  @override
  Widget build(BuildContext context) {
    final connected =
        controller.transportStatus == MeshTransportStatus.connected;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            controller.transportLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: connected ? const Color(0xff85e6bd) : Colors.white60,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _showDevices(context, controller),
            icon: Icon(
              connected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
            ),
            label: Text(connected ? 'Connecte' : 'Meshtastic'),
          ),
        ],
      ),
    );
  }
}

Future<void> _showDevices(
  BuildContext context,
  LoracordController controller,
) async {
  await controller.scanAndRequestPermissions();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Modules Meshtastic',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (controller.devices.isEmpty)
            const ListTile(
              leading: Icon(Icons.bluetooth_disabled),
              title: Text('Aucun module trouve'),
              subtitle: Text(
                'Verifie que le node est allume et visible en BLE.',
              ),
            ),
          for (final device in controller.devices)
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(device.name),
              subtitle: Text(
                device.rssi == null
                    ? device.id
                    : '${device.id} | RSSI ${device.rssi}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                controller.connect(device);
              },
            ),
        ],
      );
    },
  );
}

Future<void> _showPairingPin(
  BuildContext context,
  LoracordController controller,
  MeshDevice device,
) async {
  final input = TextEditingController();
  final pin = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('PIN Bluetooth Meshtastic'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            device.name,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            controller.transportLine,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 16,
            decoration: const InputDecoration(
              labelText: 'PIN',
              hintText: '123456',
              counterText: '',
            ),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const Text('Appairer'),
        ),
      ],
    ),
  );
  input.dispose();
  if (pin != null && pin.trim().isNotEmpty) {
    await controller.submitPairingPin(pin);
  }
}

Future<void> _showCreateGuild(
  BuildContext context,
  LoracordController controller,
) async {
  final input = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Creer un serveur'),
      content: TextField(
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nom'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const Text('Creer'),
        ),
      ],
    ),
  );
  input.dispose();
  if (value != null) controller.createGuild(value);
}

Future<void> _showJoinInvite(
  BuildContext context,
  LoracordController controller,
) async {
  final input = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Invitation'),
      content: TextField(
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Code LC-...'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const Text('Rejoindre'),
        ),
      ],
    ),
  );
  input.dispose();
  if (value != null) controller.joinInvite(value);
}

Future<void> _showCreateChannel(
  BuildContext context,
  LoracordController controller,
) async {
  final input = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Creer un salon'),
      content: TextField(
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nom du salon'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const Text('Creer'),
        ),
      ],
    ),
  );
  input.dispose();
  if (value != null) controller.createChannel(value);
}

Future<void> _showAddDirectContact(
  BuildContext context,
  LoracordController controller,
) async {
  final idInput = TextEditingController();
  final nameInput = TextEditingController();
  final keyInput = TextEditingController();
  final value = await showDialog<({String id, String name, String key})>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ajouter un DM'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: idInput,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Invitation LDM-... ou ID u...',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: nameInput,
            decoration: const InputDecoration(labelText: 'Pseudo'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: keyInput,
            decoration: const InputDecoration(
              labelText: 'Cle 64 hex manuelle (optionnel)',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Mon invitation DM',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            controller.directInviteCode,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            id: idInput.text,
            name: nameInput.text,
            key: keyInput.text,
          )),
          child: const Text('Ajouter'),
        ),
      ],
    ),
  );
  idInput.dispose();
  nameInput.dispose();
  keyInput.dispose();
  if (value != null) {
    controller.addDirectContact(value.id, value.name, sharedKey: value.key);
  }
}
