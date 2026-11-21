// App lock: PIN (always) + fingerprint (optional). Wraps the whole app via LockGate.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class AppLock {
  static const _storage = FlutterSecureStorage();
  static const _kHash = 'lock_hash';
  static const _kSalt = 'lock_salt';
  static const _kBio = 'lock_bio';
  static const _kFails = 'lock_fails';
  static const _kUntil = 'lock_until';
  static final _auth = LocalAuthentication();

  static Future<bool> isEnabled() async => (await _storage.read(key: _kHash)) != null;
  static Future<bool> biometricEnabled() async => (await _storage.read(key: _kBio)) == '1';
  static Future<void> setBiometric(bool on) =>
      _storage.write(key: _kBio, value: on ? '1' : '0');

  /// Slow-ish hash so a stolen copy of the stored value is hard to brute-force.
  static List<int> _derive(List<int> salt, String pin) {
    var d = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;
    for (var i = 0; i < 20000; i++) {
      d = sha256.convert([...d, ...salt]).bytes;
    }
    return d;
  }

  static Future<void> setPin(String pin) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    await _storage.write(key: _kSalt, value: base64Encode(salt));
    await _storage.write(key: _kHash, value: base64Encode(_derive(salt, pin)));
    await _resetFails();
  }

  static Future<void> clear() async {
    for (final k in [_kHash, _kSalt, _kBio, _kFails, _kUntil]) {
      await _storage.delete(key: k);
    }
  }

  static Future<void> _resetFails() async {
    await _storage.delete(key: _kFails);
    await _storage.delete(key: _kUntil);
  }

  /// Seconds left in a "too many wrong PINs" lockout (0 if none).
  static Future<int> lockedSeconds() async {
    final until = int.tryParse(await _storage.read(key: _kUntil) ?? '') ?? 0;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? (left / 1000).ceil() : 0;
  }

  static Future<bool> verify(String pin) async {
    if (await lockedSeconds() > 0) return false;
    final saltB64 = await _storage.read(key: _kSalt);
    final hashB64 = await _storage.read(key: _kHash);
    if (saltB64 == null || hashB64 == null) return true;

    final expected = base64Decode(hashB64);
    final actual = _derive(base64Decode(saltB64), pin);
    var diff = expected.length ^ actual.length;
    for (var i = 0; i < expected.length && i < actual.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    if (diff == 0) {
      await _resetFails();
      return true;
    }

    final fails = (int.tryParse(await _storage.read(key: _kFails) ?? '') ?? 0) + 1;
    await _storage.write(key: _kFails, value: '$fails');
    if (fails >= 5) {
      // 30s, 60s, 2min ... up to 1 hour
      final secs = min(3600, 30 * (1 << min(fails - 5, 7)));
      final until = DateTime.now().millisecondsSinceEpoch + secs * 1000;
      await _storage.write(key: _kUntil, value: '$until');
    }
    return false;
  }

  static Future<bool> biometricAvailable() async {
    try {
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> tryBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Phone Remote',
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Covers the whole app (including every screen) while locked.
class LockGate extends StatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  // Short trips away (like the camera permission pop-up) don't re-lock the app.
  static const _grace = Duration(seconds: 30);
  bool _ready = false;
  bool _locked = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final enabled = await AppLock.isEnabled();
    if (mounted) {
      setState(() {
        _locked = enabled;
        _ready = true;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _pausedAt != null) {
      final away = DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (away > _grace) _lockIfEnabled();
    }
  }

  Future<void> _lockIfEnabled() async {
    if (await AppLock.isEnabled() && mounted) setState(() => _locked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const ColoredBox(color: Colors.black);
    return Stack(
      children: [
        widget.child,
        if (_locked)
          Positioned.fill(
            child: LockScreen(onUnlocked: () => setState(() => _locked = false)),
          ),
      ],
    );
  }
}

class LockScreen extends StatelessWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});

  @override
  Widget build(BuildContext context) {
    // This sits above the app's Navigator, so it needs its own Overlay for the text field.
    return Overlay(
      initialEntries: [OverlayEntry(builder: (_) => _LockForm(onUnlocked: onUnlocked))],
    );
  }
}

class _LockForm extends StatefulWidget {
  final VoidCallback onUnlocked;
  const _LockForm({required this.onUnlocked});

  @override
  State<_LockForm> createState() => _LockFormState();
}

class _LockFormState extends State<_LockForm> {
  final _pin = TextEditingController();
  String? _message;
  bool _busy = false;
  bool _bio = false;

  @override
  void initState() {
    super.initState();
    _startBiometric();
  }

  Future<void> _startBiometric() async {
    final on = await AppLock.biometricEnabled();
    if (!mounted) return;
    setState(() => _bio = on);
    if (on) _useBiometric();
  }

  Future<void> _useBiometric() async {
    if (await AppLock.tryBiometric() && mounted) widget.onUnlocked();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final wait = await AppLock.lockedSeconds();
    if (!mounted) return;
    if (wait > 0) {
      setState(() {
        _busy = false;
        _message = 'Too many wrong attempts. Try again in ${wait}s.';
      });
      return;
    }
    final ok = await AppLock.verify(_pin.text);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _busy = false;
      _pin.clear();
      _message = 'Wrong PIN.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock, size: 56),
                const SizedBox(height: 16),
                const Text('Phone Remote is locked'),
                const SizedBox(height: 24),
                TextField(
                  controller: _pin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    labelText: 'PIN',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_message!, style: const TextStyle(color: Colors.redAccent)),
                  ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _busy ? null : _submit, child: const Text('Unlock')),
                if (_bio)
                  TextButton.icon(
                    onPressed: _useBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Use fingerprint'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings: turn the lock on/off, change the PIN, enable the fingerprint.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  bool _loading = true;
  bool _enabled = false;
  bool _bio = false;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppLock.isEnabled();
    final bio = await AppLock.biometricEnabled();
    final available = await AppLock.biometricAvailable();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _bio = bio;
      _bioAvailable = available;
      _loading = false;
    });
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> _askPin(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<String?> _chooseNewPin() async {
    final first = await _askPin('Choose a PIN (4 to 8 digits)');
    if (first == null || !mounted) return null;
    if (first.length < 4) {
      _toast('Use at least 4 digits.');
      return null;
    }
    final second = await _askPin('Repeat the PIN');
    if (second == null || !mounted) return null;
    if (second != first) {
      _toast("The PINs didn't match.");
      return null;
    }
    return first;
  }

  Future<bool> _confirmCurrentPin() async {
    final current = await _askPin('Enter your current PIN');
    if (current == null || !mounted) return false;
    final ok = await AppLock.verify(current);
    if (!ok && mounted) {
      final wait = await AppLock.lockedSeconds();
      _toast(wait > 0 ? 'Too many attempts. Try again in ${wait}s.' : 'Wrong PIN.');
    }
    return ok;
  }

  Future<void> _toggleLock(bool on) async {
    if (on) {
      final pin = await _chooseNewPin();
      if (pin != null) await AppLock.setPin(pin);
    } else if (await _confirmCurrentPin()) {
      await AppLock.clear();
    }
    _load();
  }

  Future<void> _changePin() async {
    if (!await _confirmCurrentPin()) return;
    final pin = await _chooseNewPin();
    if (pin != null) {
      await AppLock.setPin(pin);
      if (mounted) _toast('PIN changed.');
    }
  }

  Future<void> _toggleBiometric(bool on) async {
    if (on) {
      if (await AppLock.tryBiometric()) {
        await AppLock.setBiometric(true);
      } else if (mounted) {
        _toast("Fingerprint didn't work, or it isn't set up on this phone.");
      }
    } else {
      await AppLock.setBiometric(false);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App lock')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('Lock the app with a PIN'),
                  subtitle: const Text('Asked on open, and after the app has been away for a while'),
                  value: _enabled,
                  onChanged: _toggleLock,
                ),
                if (_enabled) ...[
                  ListTile(
                    title: const Text('Change PIN'),
                    leading: const Icon(Icons.password),
                    onTap: _changePin,
                  ),
                  SwitchListTile(
                    title: const Text('Unlock with fingerprint'),
                    subtitle: Text(_bioAvailable
                        ? 'The PIN still works as a backup'
                        : 'No fingerprint is set up on this phone'),
                    value: _bio,
                    onChanged: _bioAvailable ? _toggleBiometric : null,
                  ),
                ],
              ],
            ),
    );
  }
}
