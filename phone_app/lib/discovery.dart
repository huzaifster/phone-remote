// Finds the PC on the local Wi-Fi (mDNS) when its saved IP address stops working.
import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart';

/// Returns the PC's current IP address, or null if it can't be found.
/// Only a PC announcing the same certificate fingerprint prefix as the one we paired
/// with is considered. (The TLS connection then checks the FULL fingerprint, so a fake
/// announcement can't trick the phone.)
Future<String?> findPcOnLan(String fingerprint,
    {Duration timeout = const Duration(seconds: 6)}) async {
  final prefix = fingerprint.substring(0, 16);
  final found = Completer<String?>();
  Discovery? discovery;
  try {
    discovery = await startDiscovery(
      '_phoneremote._tcp',
      autoResolve: true,
      ipLookupType: IpLookupType.v4,
    );
    discovery.addServiceListener((service, status) {
      if (status != ServiceStatus.found || found.isCompleted) return;

      final txtBytes = service.txt?['fp'];
      final txt = txtBytes == null ? null : String.fromCharCodes(txtBytes);
      final nameMatches = service.name?.contains(prefix) ?? false;
      if (txt != prefix && !nameMatches) return;

      final addresses = service.addresses;
      if (addresses != null && addresses.isNotEmpty) {
        found.complete(addresses.first.address);
        return;
      }
      final host = InternetAddress.tryParse(service.host ?? '');
      if (host != null) found.complete(host.address);
    });
    return await found.future.timeout(timeout, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    if (discovery != null) {
      try {
        await stopDiscovery(discovery);
      } catch (_) {}
    }
  }
}
