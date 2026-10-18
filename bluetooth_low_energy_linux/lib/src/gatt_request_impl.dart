import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:dbus/dbus.dart';

sealed class PendingGATTRequest {
  PendingGATTRequest({required this.id, required this.central});

  final int id;
  final Central central;
  final Completer<DBusMethodResponse> response =
      Completer<DBusMethodResponse>();

  void complete(DBusMethodResponse value) {
    if (!response.isCompleted) response.complete(value);
  }
}

final class GATTReadRequestImpl extends PendingGATTRequest
    implements GATTReadRequest {
  GATTReadRequestImpl({
    required super.id,
    required super.central,
    required this.offset,
  });

  @override
  final int offset;
}

final class GATTWriteRequestImpl extends PendingGATTRequest
    implements GATTWriteRequest {
  GATTWriteRequestImpl({
    required super.id,
    required super.central,
    required this.offset,
    required this.value,
    required this.type,
  });

  @override
  final int offset;
  @override
  final Uint8List value;
  @override
  final GATTCharacteristicWriteType type;
}
