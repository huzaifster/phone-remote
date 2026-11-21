// Phone Remote: secure pairing, live view, power controls, auto-discovery,
// background notifications and app lock.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_lock.dart';
import 'background_watch.dart';
import 'secure_connection.dart';

void main() => runApp(const RemoteViewApp());

// ---------- clear, specific error messages ----------
const _scanHint =
    'On your PC, right-click the Phone Remote icon in the system tray (near the clock) '
    'and choose "Pair new phone...". Then scan the QR code that appears.';

bool _isCertError(Object e) =>
    e is TlsException ||
    e.toString().contains('CERTIFICATE_VERIFY_FAILED') ||
    e.toString().contains('HandshakeException');

/// Turns a failed connection into a message that says what actually went wrong.
String connectErrorText(Object e, String ip) {
  if (e is PcRefusedException) {
    return 'The PC closed the connection without accepting this phone.\n\n'
        'Most likely this phone was removed on the PC ("Manage phones"). Tap Unpair, then pair again.\n\n'
        'It can also happen if the PC blocked this phone for 10 minutes after too many failed '
        'attempts, or if the PC was shutting down.';
  }
  if (_isCertError(e)) {
    return "The PC's security certificate doesn't match the one this phone paired with. "
        'Phone Remote may have been reinstalled or its data deleted on the PC. '
        'Tap Unpair, then pair again.';
  }
  if (e is TimeoutException) {
    return "Your PC at $ip didn't answer in time.\n\n"
        "Make sure the PC is awake, Phone Remote is running (look for its icon in the system tray), "
        'and both devices are on the same Wi-Fi. Then tap Connect again.';
  }
  if (e.toString().contains('PC not found on this network')) {
    return "Couldn't reach your PC at $ip, and it wasn't found on this Wi-Fi.\n\n"
        '• Is the PC on and awake?\n'
        '• Is Phone Remote running? (icon in the system tray)\n'
        '• Are the phone and PC on the same Wi-Fi?\n'
        '• Does Windows Firewall allow Phone Remote on private networks?\n\n'
        'If the PC was reinstalled or its Phone Remote data was deleted, tap Unpair and pair again.';
  }
  return "Couldn't connect to your PC at $ip.\n\nDetails: $e";
}

/// Turns a failed pairing attempt into a message that says what actually went wrong.
String pairErrorText(Object e, String? ip) {
  final where = ip == null ? 'the PC' : 'the PC at $ip';
  final text = e.toString();
  if (e is FormatException ||
      e is TypeError ||
      e is NoSuchMethodError ||
      text.contains('Not a PC agent QR code')) {
    return "That isn't a Phone Remote QR code.\n\n$_scanHint";
  }
  if (text.contains('Pairing failed')) {
    return 'The PC rejected this QR code. It has expired (codes last 2 minutes), was already '
        'used, or a newer code was shown.\n\n'
        'On the PC, right-click the tray icon and choose "Pair new phone..." to get a fresh code.';
  }
  if (_isCertError(e)) {
    return "$where doesn't match this QR code, so the phone refused to connect. "
        'The code may be old (Phone Remote was reinstalled) or you may be on a different network. '
        'Show a fresh code on the PC and try again.';
  }
  if (e is TimeoutException) {
    return "$where didn't answer in time.\n\n"
        'Make sure Phone Remote is running on the PC, both devices are on the same Wi-Fi, and '
        'Windows Firewall allows Phone Remote on private networks.';
  }
  if (e is StateError) {
    return '$where closed the connection.\n\n'
        'After several failed attempts the PC blocks a phone for 10 minutes. Wait a little, then '
        'try again with a fresh QR code.';
  }
  if (e is SocketException) {
    return "Couldn't connect to $where.\n\n"
        'Check that Phone Remote is running, both devices are on the same Wi-Fi, and Windows '
        'Firewall allows it. If the PC changed networks, show a fresh QR code.';
  }
  return 'Pairing failed: $e';
}

class RemoteViewApp extends StatelessWidget {
  const RemoteViewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phone Remote',
      builder: (context, child) => LockGate(child: child ?? const SizedBox.shrink()),
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  PairedPc? _pc;
  bool _loading = true;
  bool _busy = false;
  bool _autoTried = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pc = await PairingStore.load();
    if (!mounted) return;
    setState(() {
      _pc = pc;
      _loading = false;
    });
    if (pc != null && !_autoTried) {
      _autoTried = true; // connect by itself the first time the app opens
      _connect();
    }
  }

  Future<void> _scan() async {
    final paired = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (paired == true) _load();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conn = await connectToPc(_pc!);
      if (!mounted) return;
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute<String>(builder: (_) => WindowListScreen(conn: conn)),
      );
      conn.close();
      if (result == 'lost' && mounted) {
        setState(() => _error =
            'The connection to your PC ended. It may have shut down, gone to sleep, '
            'been closed, or lost Wi-Fi. Tap Connect to try again.');
      }
    } catch (e) {
      setState(() => _error = connectErrorText(e, _pc!.ip));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpair() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair this PC?'),
        content: const Text(
            'This phone will forget the PC. To fully remove this phone, also open Phone Remote on '
            'the PC (right-click its tray icon, then "Manage phones...") and revoke it there.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unpair')),
        ],
      ),
    );
    if (sure == true) {
      await PairingStore.clear();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phone Remote'),
        actions: [
          IconButton(
            tooltip: 'App lock',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SecurityScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_pc == null) ...[
              const Text(
                'No PC paired yet.\n\n'
                'On your PC, open Phone Remote (right-click its icon in the system tray near the '
                'clock) and choose "Pair new phone...". Then tap "Scan QR code" below and scan the '
                'code that appears. The code lasts 2 minutes and works once.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR code'),
              ),
            ] else ...[
              Text('Paired PC: ${_pc!.ip}', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: Text(_busy ? 'Connecting...' : 'Connect'),
              ),
              TextButton(onPressed: _unpair, child: const Text('Unpair')),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _handled = false;
  bool _failed = false;
  String _status = 'Point the camera at the QR code shown on your PC.\n\n$_scanHint';

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    _handled = true; // the token works only once, so never try twice
    String? ip;
    setState(() => _status = 'Pairing...');
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['v'] != 1) throw Exception('Not a PC agent QR code');
      ip = data['ip'] as String?;
      final pc = await pairWithPc(
        ip: data['ip'] as String,
        port: data['port'] as int,
        fingerprint: data['fp'] as String,
        token: data['token'] as String,
        deviceName: 'Android phone',
      );
      await PairingStore.save(pc);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = pairErrorText(e, ip);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair with PC')),
      body: Column(
        children: [
          Expanded(
            child: _failed
                ? const Center(child: Icon(Icons.error_outline, size: 64))
                : MobileScanner(
                    onDetect: _onDetect,
                    errorBuilder: (context, error, [child]) {
                      final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            denied
                                ? "Camera permission is turned off for Phone Remote. Open your phone's "
                                    'Settings > Apps > Phone Remote > Permissions, allow Camera, then come back.'
                                : "The camera couldn't start (${error.errorCode.name}). Close other "
                                    'apps that are using the camera and try again.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(_status, textAlign: TextAlign.center),
                if (_failed)
                  TextButton(
                    onPressed: () => setState(() {
                      _failed = false;
                      _handled = false;
                      _status = 'Point the camera at the QR code shown on your PC.\n\n$_scanHint';
                    }),
                    child: const Text('Try again'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WindowListScreen extends StatefulWidget {
  final Connection conn;
  const WindowListScreen({super.key, required this.conn});

  @override
  State<WindowListScreen> createState() => _WindowListScreenState();
}

class _WindowListScreenState extends State<WindowListScreen> {
  List<Map<String, dynamic>> _windows = [];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.conn.stream.listen((data) {
      if (data is String) {
        final msg = jsonDecode(data);
        if (msg['type'] == 'windows') {
          setState(() => _windows = List<Map<String, dynamic>>.from(msg['windows']));
        }
      }
    }, onDone: () {
      if (mounted) Navigator.of(context).maybePop('lost');
    });
    _refresh();
  }

  void _refresh() => widget.conn.send({'type': 'list'});

  void _open(String target, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewerScreen(conn: widget.conn, target: target, title: title),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your PC'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PowerScreen(conn: widget.conn)),
            ),
          ),
        ],
      ),
      body: Column(children: [
        PowerBanner(conn: widget.conn),
        Expanded(
          child: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.desktop_windows),
            title: const Text('Desktop'),
            onTap: () => _open('desktop', 'Desktop'),
          ),
          const Divider(),
          for (final w in _windows)
            ListTile(
              leading: const Icon(Icons.web_asset),
              title: Text(w['title'], maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  w['minimized'] == true ? '${w['process']} (minimized)' : w['process']),
              onTap: () => _open('${w['id']}', w['title']),
            ),
        ],
      ),
        ),
      ]),
    );
  }
}

class ViewerScreen extends StatefulWidget {
  final Connection conn;
  final String target;
  final String title;
  const ViewerScreen(
      {super.key, required this.conn, required this.target, required this.title});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  Uint8List? _frame;
  String? _error;
  bool _auto = false; // auto-refresh every 2s, off by default
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.conn.stream.listen((data) {
      if (data is Uint8List) {
        setState(() {
          _frame = data;
          _error = null;
        });
      } else if (data is String) {
        final msg = jsonDecode(data);
        if (msg['type'] == 'error') {
          setState(() {
            _error = msg['message'];
            _auto = false;
          });
        }
      }
    });
    _capture();
  }

  /// Ask the PC for ONE screenshot.
  void _capture() {
    setState(() => _error = null);
    widget.conn.send({'type': 'capture', 'target': widget.target});
  }

  void _toggleAuto() {
    setState(() => _auto = !_auto);
    if (_auto) {
      widget.conn.send({'type': 'watch', 'target': widget.target});
    } else {
      widget.conn.send({'type': 'stop'});
    }
  }

  @override
  void dispose() {
    widget.conn.send({'type': 'stop'});
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Auto-refresh every 2 seconds',
            icon: Icon(_auto ? Icons.sync : Icons.sync_disabled),
            onPressed: _toggleAuto,
          ),
          IconButton(
            tooltip: 'Take a new screenshot',
            icon: const Icon(Icons.refresh),
            onPressed: _capture,
          ),
        ],
      ),
      body: Column(children: [
        PowerBanner(conn: widget.conn),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!, textAlign: TextAlign.center))
              : _frame == null
                  ? const Center(child: CircularProgressIndicator())
                  // The zoom area fills the whole screen (not just the image's own box),
                  // so zoomed-in content is no longer cut off by the letterbox edges.
                  : InteractiveViewer(
                      maxScale: 8,
                      child: Image.memory(
                        _frame!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
        ),
      ]),
    );
  }
}


/// Countdown banner shown on every screen while a power action is pending.
class PowerBanner extends StatefulWidget {
  final Connection conn;
  const PowerBanner({super.key, required this.conn});

  @override
  State<PowerBanner> createState() => _PowerBannerState();
}

class _PowerBannerState extends State<PowerBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PendingPower?>(
      valueListenable: widget.conn.pendingPower,
      builder: (context, p, _) {
        if (p == null) return const SizedBox.shrink();
        final left = p.endsAt.difference(DateTime.now()).inSeconds.clamp(0, 999).toInt();
        final label = {
              'shutdown': 'Shutting down',
              'restart': 'Restarting',
              'sleep': 'Going to sleep',
            }[p.action] ??
            p.action;
        return MaterialBanner(
          leading: const Icon(Icons.power_settings_new),
          content: Text('$label in ${left}s'),
          actions: [
            TextButton(onPressed: widget.conn.cancelPower, child: const Text('CANCEL')),
          ],
        );
      },
    );
  }
}

class PowerScreen extends StatefulWidget {
  final Connection conn;
  const PowerScreen({super.key, required this.conn});

  @override
  State<PowerScreen> createState() => _PowerScreenState();
}

class _PowerScreenState extends State<PowerScreen> {
  static const _waitOptions = [1, 2, 3, 5, 10, 15];
  late int _quietMinutes;

  @override
  void initState() {
    super.initState();
    final fromPc = widget.conn.autoStatus.value?.quietMinutes ?? 3;
    _quietMinutes = _waitOptions.contains(fromPc) ? fromPc : 3;
  }

  Future<void> _confirm(String action, String title, String warning) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(warning),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(title)),
        ],
      ),
    );
    if (ok == true) widget.conn.requestPower(action);
  }

  Future<void> _setAuto(bool on) async {
    widget.conn.setAutoShutdown(on, _quietMinutes);
    try {
      if (on) {
        await BackgroundWatch.start(); // keeps notifications working with the app closed
      } else {
        await BackgroundWatch.stop();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't start background notifications. Check that notifications are allowed "
                "for Phone Remote in your phone's settings. The PC will still shut down when "
                "finished, but this phone won't warn you first.")));
      }
    }
  }

  String _describe(AutoStatus s) {
    switch (s.state) {
      case 'waiting':
        return 'Waiting for a download or install to start...';
      case 'busy':
        return 'Activity detected. The PC will shut down once it goes quiet.';
      case 'quiet':
        return 'Quiet for ${s.quietSeconds ~/ 60}m ${s.quietSeconds % 60}s '
            '(shuts down after ${s.quietMinutes}m).';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Power')),
      body: Column(children: [
        PowerBanner(conn: widget.conn),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ValueListenableBuilder<AutoStatus?>(
                valueListenable: widget.conn.autoStatus,
                builder: (context, s, _) {
                  final enabled = s?.enabled ?? false;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Shut down when finished'),
                            subtitle: const Text(
                                'Turns the PC off after downloads or installs go quiet'),
                            value: enabled,
                            onChanged: (v) => _setAuto(v),
                          ),
                          Row(children: [
                            const Text('Wait for quiet:'),
                            const SizedBox(width: 12),
                            DropdownButton<int>(
                              value: _quietMinutes,
                              items: [
                                for (final m in _waitOptions)
                                  DropdownMenuItem(value: m, child: Text('$m min')),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() => _quietMinutes = v);
                                if (enabled) widget.conn.setAutoShutdown(true, v);
                              },
                            ),
                          ]),
                          if (enabled && s != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(_describe(s)),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.power_settings_new),
                title: const Text('Shut down'),
                onTap: () => _confirm('shutdown', 'Shut down',
                    'The PC will shut down in 30 seconds. You can cancel before then.'),
              ),
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('Restart'),
                onTap: () => _confirm('restart', 'Restart',
                    'The PC will restart in 30 seconds. You can cancel before then.'),
              ),
              ListTile(
                leading: const Icon(Icons.bedtime),
                title: const Text('Sleep'),
                onTap: () => _confirm('sleep', 'Sleep',
                    'The PC will go to sleep in 30 seconds. While asleep it can\'t be reached '
                    'from this app, and you\'ll need to wake it at the PC.'),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
