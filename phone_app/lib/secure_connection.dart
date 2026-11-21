// Phase 3: certificate pinning + mutual TLS + secure storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'discovery.dart';

/// Everything the phone needs to remember about its paired PC.
class PairedPc {
  final String ip;
  final int port;
  final String fingerprint; // SHA-256 of the PC's certificate (from the QR code)
  final String certPem; // this phone's certificate
  final String keyPem; // this phone's private key

  PairedPc(this.ip, this.port, this.fingerprint, this.certPem, this.keyPem);

  PairedPc withIp(String newIp) => PairedPc(newIp, port, fingerprint, certPem, keyPem);

  Map<String, dynamic> toJson() =>
      {'ip': ip, 'port': port, 'fp': fingerprint, 'cert': certPem, 'key': keyPem};

  factory PairedPc.fromJson(Map<String, dynamic> j) =>
      PairedPc(j['ip'], j['port'], j['fp'], j['cert'], j['key']);
}

/// Stored in the Android Keystore-backed secure storage.
class PairingStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'paired_pc';

  static Future<PairedPc?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    return PairedPc.fromJson(jsonDecode(raw));
  }

  static Future<void> save(PairedPc pc) =>
      _storage.write(key: _key, value: jsonEncode(pc.toJson()));

  static Future<void> clear() => _storage.delete(key: _key);
}

/// Wraps the socket so every screen can share one connection.
/// The PC answered but refused us (this phone was revoked or isn't paired).
class PcRefusedException implements Exception {
  @override
  String toString() => 'The PC refused this phone.';
}

/// A shutdown / restart / sleep countdown running on the PC.
class PendingPower {
  final String action;
  final DateTime endsAt;
  PendingPower(this.action, this.endsAt);
}

/// State of the "shut down when finished" watcher on the PC.
class AutoStatus {
  final bool enabled;
  final String state; // off | waiting | busy | quiet
  final int quietMinutes;
  final int quietSeconds;
  AutoStatus(this.enabled, this.state, this.quietMinutes, this.quietSeconds);
}

class Connection {
  final WebSocketChannel channel;
  final _controller = StreamController<dynamic>.broadcast();
  final _ready = Completer<void>();
  final pendingPower = ValueNotifier<PendingPower?>(null);
  final autoStatus = ValueNotifier<AutoStatus?>(null);

  Stream<dynamic> get stream => _controller.stream;
  Future<void> get ready => _ready.future;

  Connection(this.channel) {
    _ready.future.ignore();
    channel.stream.listen(
      (data) {
        if (data is String) {
          final msg = jsonDecode(data);
          switch (msg['type']) {
            case 'ready':
              if (!_ready.isCompleted) _ready.complete(); // PC accepted our certificate
              return;
            case 'power':
              pendingPower.value = PendingPower(
                  msg['action'], DateTime.now().add(Duration(seconds: msg['seconds'] as int)));
              return;
            case 'power_cancelled':
              pendingPower.value = null;
              return;
            case 'auto_status':
              autoStatus.value = AutoStatus(msg['enabled'] as bool, msg['state'] as String,
                  msg['quiet_minutes'] as int, msg['quiet_seconds'] as int);
              return;
          }
        }
        _controller.add(data);
      },
      onError: (e) {
        if (!_ready.isCompleted) _ready.completeError(e);
      },
      onDone: () {
        if (!_ready.isCompleted) _ready.completeError(PcRefusedException());
        _controller.close();
      },
    );
  }

  void send(Map<String, dynamic> msg) => channel.sink.add(jsonEncode(msg));

  void requestPower(String action) => send({'type': 'power', 'action': action});
  void cancelPower() => send({'type': 'power_cancel'});
  void setAutoShutdown(bool enabled, int quietMinutes) =>
      send({'type': 'auto_shutdown', 'enabled': enabled, 'quiet_minutes': quietMinutes});
  void close() => channel.sink.close();
}

/// HTTP client that ONLY trusts the PC whose fingerprint we pinned.
HttpClient _buildClient(String pinnedFingerprint, {String? certPem, String? keyPem}) {
  final ctx = SecurityContext(withTrustedRoots: false); // trust no public CAs
  if (certPem != null && keyPem != null) {
    ctx.useCertificateChainBytes(utf8.encode(certPem));
    ctx.usePrivateKeyBytes(utf8.encode(keyPem));
  }
  final client = HttpClient(context: ctx);
  client.badCertificateCallback = (X509Certificate cert, String host, int port) {
    return sha256.convert(cert.der).toString() == pinnedFingerprint;
  };
  return client;
}

/// One-time pairing: send the QR token, receive our certificate + key.
Future<PairedPc> pairWithPc({
  required String ip,
  required int port,
  required String fingerprint,
  required String token,
  required String deviceName,
}) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('wss://$ip:$port'),
    customClient: _buildClient(fingerprint),
  );
  try {
    await channel.ready.timeout(const Duration(seconds: 8));
    channel.sink.add(jsonEncode({'type': 'pair', 'token': token, 'name': deviceName}));
    final reply = await channel.stream.first.timeout(const Duration(seconds: 10));
    final msg = jsonDecode(reply as String);
    if (msg['type'] != 'paired') throw Exception(msg['message'] ?? 'Pairing failed');
    return PairedPc(ip, port, fingerprint, msg['cert'], msg['key']);
  } finally {
    channel.sink.close();
  }
}

/// One connection attempt to a specific address.
Future<Connection> _tryConnect(PairedPc pc, String ip, Duration timeout) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('wss://$ip:${pc.port}'),
    customClient: _buildClient(pc.fingerprint, certPem: pc.certPem, keyPem: pc.keyPem),
  );
  final conn = Connection(channel);
  try {
    await conn.ready.timeout(timeout);
    return conn;
  } catch (e) {
    conn.close();
    rethrow;
  }
}

/// Normal connection: pinned server + our client certificate.
/// Tries the saved address first. If that fails (the PC's IP may have changed),
/// it looks for the PC on the Wi-Fi and remembers the new address.
Future<Connection> connectToPc(PairedPc pc) async {
  try {
    return await _tryConnect(pc, pc.ip, const Duration(seconds: 4));
  } on PcRefusedException {
    rethrow; // the PC is there but doesn't accept us; searching won't help
  } catch (_) {
    // fall through to discovery
  }
  final foundIp = await findPcOnLan(pc.fingerprint);
  if (foundIp == null) throw Exception('PC not found on this network');
  final conn = await _tryConnect(pc, foundIp, const Duration(seconds: 8));
  if (foundIp != pc.ip) await PairingStore.save(pc.withIp(foundIp));
  return conn;
}
