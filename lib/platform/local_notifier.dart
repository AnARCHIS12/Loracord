import 'package:flutter/services.dart';

class LocalNotifier {
  const LocalNotifier({
    MethodChannel channel = const MethodChannel('loracord/notifications'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<void> notifyMessage({
    required String title,
    required String body,
  }) async {
    try {
      await _channel.invokeMethod<void>('message', {
        'title': title,
        'body': body,
      });
    } on MissingPluginException {
      // Desktop builds keep working without Android notification plumbing.
    }
  }
}
