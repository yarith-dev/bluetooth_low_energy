import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:dbus/dbus.dart';

/// A remote central connected to the local Linux GATT server.
final class CentralImpl implements Central {
  CentralImpl({required this.address, required this.devicePath, this.mtu = 23});

  factory CentralImpl.fromDevicePath(DBusObjectPath path, {int mtu = 23}) {
    final device = path.value.split('/').last;
    final encoded = device.startsWith('dev_') ? device.substring(4) : device;
    final candidate = encoded.replaceAll('_', ':');
    final validAddress = RegExp(
      r'^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$',
    ).hasMatch(candidate);
    return CentralImpl(
      address: validAddress
          ? candidate.toUpperCase()
          : _addressFromText(path.value),
      devicePath: path,
      mtu: mtu,
    );
  }

  final String address;
  final DBusObjectPath devicePath;
  int mtu;

  @override
  UUID get uuid => UUID.fromAddress(address);

  @override
  int get hashCode => address.hashCode;

  @override
  bool operator ==(Object other) =>
      other is CentralImpl && other.address == address;

  static String _addressFromText(String value) {
    // FNV-1a keeps the fallback stable without exposing the D-Bus path as an
    // invalid Bluetooth address. BlueZ normally always supplies dev_XX_... .
    var hash = 0xcbf29ce484222325;
    for (final byte in value.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    final hex = (hash & 0xffffffffffff).toRadixString(16).padLeft(12, '0');
    return [
      for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2),
    ].join(':').toUpperCase();
  }
}
