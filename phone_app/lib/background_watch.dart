// Keeps a connection to the PC alive in the background (Android foreground service)
// so you get a notification, with a Cancel button, when the PC is about to shut down.
import 'dart:async';
import 'dart:ui';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'secure_connection.dart';

const _cancelButtonId = 'cancel_power';
const _alertId = 42;

/// Called from the app's screens.
class BackgroundWatch {
  static bool _configured = false;

  static void _configure() {
    if (_configured) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'pc_watch',
        channelName: 'PC watcher',
        channelDescription: 'Shown while the app watches your PC in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _configured = true;
  }

  static Future<void> start() async {
    _configure();
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 777,
      notificationTitle: 'Watching your PC',
      notificationText: 'Connecting...',
      callback: startWatchCallback,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

@pragma('vm:entry-point')
void startWatchCallback() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(WatchHandler());
}

/// Runs in its own isolate while the service is alive.
class WatchHandler extends TaskHandler {
  final _notifications = FlutterLocalNotificationsPlugin();
  final _startedAt = DateTime.now();
  PairedPc? _pc;
  Connection? _conn;
  StreamSubscription? _sub;
  Timer? _retry;
  bool _stopping = false;
  bool _sawPending = false;
  String _lastText = '';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _notifications.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    _pc = await PairingStore.load();
    if (_pc == null) {
      await _finish('Phone Remote', 'This phone is not paired with a PC.');
      return;
    }
    unawaited(_connect());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopping = true;
    _retry?.cancel();
    _detach();
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _cancelButtonId) _conn?.cancelPower();
  }

  // ---------- connection ----------
  Future<void> _connect() async {
    if (_stopping) return;
    _setStatus('Looking for your PC...');
    try {
      final conn = await connectToPc(_pc!);
      if (_stopping) {
        conn.close();
        return;
      }
      _conn = conn;
      conn.pendingPower.addListener(_onPending);
      conn.autoStatus.addListener(_onAuto);
      _sub = conn.stream.listen((_) {}, onDone: _onLost);
      _onPending();
      _onAuto();
    } on PcRefusedException {
      await _finish('Phone Remote', 'This phone is no longer paired with your PC.');
    } catch (_) {
      _retry = Timer(const Duration(seconds: 20), _connect);
    }
  }

  void _detach() {
    _conn?.pendingPower.removeListener(_onPending);
    _conn?.autoStatus.removeListener(_onAuto);
    _sub?.cancel();
    _sub = null;
    _conn?.close();
    _conn = null;
  }

  void _onLost() {
    if (_stopping) return;
    final pending = _conn?.pendingPower.value;
    _detach();
    if (pending != null) {
      // The connection ended because the PC is doing what it was told to.
      final message = {
            'shutdown': 'Your PC has shut down.',
            'restart': 'Your PC is restarting.',
            'sleep': 'Your PC went to sleep.',
          }[pending.action] ??
          'Your PC went offline.';
      _finish('Phone Remote', message);
    } else {
      _setStatus('Connection lost. Trying again...');
      _retry = Timer(const Duration(seconds: 10), _connect);
    }
  }

  // ---------- reacting to what the PC says ----------
  void _onPending() {
    final p = _conn?.pendingPower.value;
    if (p == null) {
      if (_sawPending) {
        _sawPending = false;
        if (_conn?.autoStatus.value?.enabled != true) {
          _stop(); // it was cancelled and nothing is left to watch
        } else {
          _lastText = '';
          _onAuto();
        }
      }
      return;
    }
    _sawPending = true;
    final secs = p.endsAt.difference(DateTime.now()).inSeconds.clamp(0, 999).toInt();
    final what = {'shutdown': 'shut down', 'restart': 'restart', 'sleep': 'go to sleep'}[p.action] ??
        p.action;
    _alert('Your PC will $what in ${secs}s', 'Open this and tap Cancel to stop it.');
    FlutterForegroundTask.updateService(
      notificationTitle: 'PC will $what soon',
      notificationText: 'Tap Cancel to stop it.',
      notificationButtons: [const NotificationButton(id: _cancelButtonId, text: 'Cancel')],
    );
  }

  void _onAuto() {
    final s = _conn?.autoStatus.value;
    if (s == null || _conn?.pendingPower.value != null) return;
    final justStarted = DateTime.now().difference(_startedAt).inSeconds < 20;
    if (!s.enabled && !justStarted) {
      _stop(); // "shut down when finished" was switched off
      return;
    }
    final text = switch (s.state) {
      'waiting' => 'Waiting for a download or install to start',
      'busy' => 'Activity detected. Will shut down when it finishes',
      'quiet' => 'Quiet for ${s.quietSeconds ~/ 60} of ${s.quietMinutes} min',
      _ => 'Connected',
    };
    _setStatus(text);
  }

  // ---------- notifications ----------
  void _setStatus(String text) {
    if (text == _lastText) return;
    _lastText = text;
    FlutterForegroundTask.updateService(
      notificationTitle: 'Watching your PC',
      notificationText: text,
      notificationButtons: const [],
    );
  }

  Future<void> _alert(String title, String body) {
    return _notifications.show(
      _alertId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'pc_alerts',
          'PC alerts',
          channelDescription: 'Warnings before your PC shuts down.',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }

  Future<void> _finish(String title, String body) async {
    _stopping = true;
    await _alert(title, body);
    await FlutterForegroundTask.stopService();
  }

  void _stop() {
    _stopping = true;
    FlutterForegroundTask.stopService();
  }
}
