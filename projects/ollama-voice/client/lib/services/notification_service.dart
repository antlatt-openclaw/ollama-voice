import 'dart:async';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  // Notification IDs
  static const int _responseNotificationId = 1;
  static const int _backgroundListeningNotificationId = 2;

  // Channel IDs
  static const String _responseChannelId = 'voice_responses';
  static const String _backgroundListeningChannelId = 'background_listening';

  static Future<void> init() async {
    if (_initialized) return;

    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    _initialized = true;
  }

  static Future<void> showResponseNotification(String responseText) async {
    if (!_initialized) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'voice_responses',
        'Voice Responses',
        channelDescription: 'Notifications when a voice response completes',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );
    final preview = responseText.length > 120
        ? '${responseText.substring(0, 120)}…'
        : responseText;
    await _plugin.show(_responseNotificationId, 'OpenClaw Voice', preview, details);
  }

  // ── Background Listening Notification ──────────────────────────────────────

  /// Show a persistent notification indicating the app is listening for
  /// the wake word in the background. This is required on Android to keep
  /// the app's foreground service alive while recording audio in the background.
  static Future<void> showBackgroundListeningNotification({
    String status = 'Listening for wake word…',
  }) async {
    if (!_initialized) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'background_listening',
        'Background Listening',
        channelDescription: 'Shows when the app is listening for the wake word in the background',
        importance: Importance.low, // Low priority — non-intrusive
        priority: Priority.low,
        ongoing: true, // Persistent notification — can't be swiped away
        autoCancel: false,
        showWhen: false,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: false,
        presentBadge: false,
        presentSound: false,
      ),
    );
    await _plugin.show(
      _backgroundListeningNotificationId,
      'OpenClaw Voice',
      status,
      details,
    );
  }

  /// Update the background listening notification with a new status.
  static Future<void> updateBackgroundListeningStatus(String status) async {
    await showBackgroundListeningNotification(status: status);
  }

  /// Cancel the background listening notification when the app returns to
  /// foreground or hands-free mode is disabled.
  static Future<void> cancelBackgroundListeningNotification() async {
    if (!_initialized) return;
    await _plugin.cancel(_backgroundListeningNotificationId);
  }
}