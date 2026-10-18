import 'dart:typed_data';

import 'package:bluetooth_low_energy_linux/src/bluez_gatt_application.dart';
import 'package:bluetooth_low_energy_linux/src/central_impl.dart';
import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Linux GATT application', () {
    late _Delegate delegate;
    late MutableGATTCharacteristicImpl characteristic;
    late LinuxGattCharacteristic object;

    setUp(() {
      delegate = _Delegate();
      characteristic =
          GATTCharacteristic.mutable(
                uuid: UUID.fromString('00002a00-0000-1000-8000-00805f9b34fb'),
                properties: [
                  GATTCharacteristicProperty.read,
                  GATTCharacteristicProperty.write,
                  GATTCharacteristicProperty.writeWithoutResponse,
                  GATTCharacteristicProperty.notify,
                ],
                permissions: [
                  GATTCharacteristicPermission.read,
                  GATTCharacteristicPermission.write,
                ],
                descriptors: const [],
              )
              as MutableGATTCharacteristicImpl;
      object = LinuxGattCharacteristic(
        path: DBusObjectPath('/test/service0/char0'),
        servicePath: DBusObjectPath('/test/service0'),
        characteristic: characteristic,
        descriptorPaths: const [],
        delegate: delegate,
      );
    });

    test('exports the standard BlueZ characteristic flags', () {
      final properties =
          object.interfacesAndProperties[blueZGattCharacteristicInterface]!;
      expect(
        properties['Flags']!.asStringArray(),
        containsAll(['read', 'write', 'write-without-response', 'notify']),
      );
    });

    test('uses encrypted flags without also granting plain access', () {
      final encrypted =
          GATTCharacteristic.mutable(
                uuid: UUID.fromString('00002a03-0000-1000-8000-00805f9b34fb'),
                properties: [
                  GATTCharacteristicProperty.read,
                  GATTCharacteristicProperty.write,
                ],
                permissions: [
                  GATTCharacteristicPermission.readEncrypted,
                  GATTCharacteristicPermission.writeEncrypted,
                ],
                descriptors: const [],
              )
              as MutableGATTCharacteristicImpl;
      final encryptedObject = LinuxGattCharacteristic(
        path: DBusObjectPath('/test/service0/char3'),
        servicePath: DBusObjectPath('/test/service0'),
        characteristic: encrypted,
        descriptorPaths: const [],
        delegate: delegate,
      );

      final flags = encryptedObject
          .interfacesAndProperties[blueZGattCharacteristicInterface]!['Flags']!
          .asStringArray();
      expect(flags, containsAll(['encrypt-read', 'encrypt-write']));
      expect(flags, isNot(contains('read')));
      expect(flags, isNot(contains('write')));
    });

    test('routes reads with central, MTU and offset', () async {
      final response = await object.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'ReadValue',
          values: [_options(offset: 7, mtu: 185)],
        ),
      );

      expect(response, isA<DBusMethodSuccessResponse>());
      expect(response.returnValues.single.asByteArray(), [1, 2, 3]);
      expect(delegate.lastOffset, 7);
      expect(delegate.lastCentral.address, '12:34:56:78:9A:BC');
      expect(delegate.lastCentral.mtu, 185);
    });

    test('routes write requests and preserves the write type', () async {
      final response = await object.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'WriteValue',
          values: [
            dbusBytes([9, 8, 7]),
            _options(type: 'command'),
          ],
        ),
      );

      expect(response, isA<DBusMethodSuccessResponse>());
      expect(delegate.lastValue, [9, 8, 7]);
      expect(
        delegate.lastWriteType,
        GATTCharacteristicWriteType.withoutResponse,
      );
    });

    test(
      'applies offset writes to the exported characteristic value',
      () async {
        await object.handleMethodCall(
          DBusMethodCall(
            sender: ':1.42',
            interface: blueZGattCharacteristicInterface,
            name: 'WriteValue',
            values: [
              dbusBytes([1, 2, 3]),
              _options(type: 'command'),
            ],
          ),
        );
        await object.handleMethodCall(
          DBusMethodCall(
            sender: ':1.42',
            interface: blueZGattCharacteristicInterface,
            name: 'WriteValue',
            values: [
              dbusBytes([9]),
              _options(offset: 1, type: 'command'),
            ],
          ),
        );

        final properties =
            object.interfacesAndProperties[blueZGattCharacteristicInterface]!;
        expect(properties['Value']!.asByteArray(), [1, 9, 3]);
        expect(delegate.lastOffset, 1);
      },
    );

    test('does not cache a write rejected by the application', () async {
      await object.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'WriteValue',
          values: [
            dbusBytes([1, 2, 3]),
            _options(type: 'command'),
          ],
        ),
      );
      delegate.writeResponse = DBusMethodErrorResponse(
        'org.bluez.Error.NotAuthorized',
      );

      final response = await object.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'WriteValue',
          values: [
            dbusBytes([9]),
            _options(type: 'request'),
          ],
        ),
      );

      expect(response, isA<DBusMethodErrorResponse>());
      expect(
        object
            .interfacesAndProperties[blueZGattCharacteristicInterface]!['Value']!
            .asByteArray(),
        [1, 2, 3],
      );
    });

    test('starts and stops notifications through the delegate', () async {
      final start = await object.handleMethodCall(
        const DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'StartNotify',
        ),
      );
      expect(start, isA<DBusMethodSuccessResponse>());
      expect(object.notifying, isTrue);
      expect(delegate.notificationStates, [true]);

      await object.notify(Uint8List.fromList([4, 5]));

      final stop = await object.handleMethodCall(
        const DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'StopNotify',
        ),
      );
      expect(stop, isA<DBusMethodSuccessResponse>());
      expect(object.notifying, isFalse);
      expect(delegate.notificationStates, [true, false]);
    });

    test(
      'rejects operations that are absent from characteristic flags',
      () async {
        final readOnly =
            GATTCharacteristic.mutable(
                  uuid: UUID.fromString('00002a01-0000-1000-8000-00805f9b34fb'),
                  properties: [GATTCharacteristicProperty.read],
                  permissions: [GATTCharacteristicPermission.read],
                  descriptors: const [],
                )
                as MutableGATTCharacteristicImpl;
        final readOnlyObject = LinuxGattCharacteristic(
          path: DBusObjectPath('/test/service0/char1'),
          servicePath: DBusObjectPath('/test/service0'),
          characteristic: readOnly,
          descriptorPaths: const [],
          delegate: delegate,
        );

        final response = await readOnlyObject.handleMethodCall(
          DBusMethodCall(
            sender: ':1.42',
            interface: blueZGattCharacteristicInterface,
            name: 'WriteValue',
            values: [
              dbusBytes([1]),
              _options(),
            ],
          ),
        );

        expect(response, isA<DBusMethodErrorResponse>());
        expect(
          (response as DBusMethodErrorResponse).errorName,
          'org.bluez.Error.NotPermitted',
        );
      },
    );

    test('rejects reads from a write-only descriptor', () async {
      final descriptor =
          GATTDescriptor.mutable(
                uuid: UUID.fromString('00002901-0000-1000-8000-00805f9b34fb'),
                permissions: [GATTCharacteristicPermission.write],
              )
              as MutableGATTDescriptorImpl;
      final descriptorObject = LinuxGattDescriptor(
        path: DBusObjectPath('/test/service0/char0/desc0'),
        characteristicPath: DBusObjectPath('/test/service0/char0'),
        descriptor: descriptor,
        delegate: delegate,
      );

      final response = await descriptorObject.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattDescriptorInterface,
          name: 'ReadValue',
          values: [_options()],
        ),
      );

      expect(response, isA<DBusMethodErrorResponse>());
      expect(
        (response as DBusMethodErrorResponse).errorName,
        'org.bluez.Error.NotPermitted',
      );
    });

    test('rejects an immutable read past the end of its value', () async {
      final immutable =
          GATTCharacteristic.immutable(
                uuid: UUID.fromString('00002a02-0000-1000-8000-00805f9b34fb'),
                value: Uint8List.fromList([1, 2]),
                descriptors: const [],
              )
              as MutableGATTCharacteristicImpl;
      final immutableObject = LinuxGattCharacteristic(
        path: DBusObjectPath('/test/service0/char2'),
        servicePath: DBusObjectPath('/test/service0'),
        characteristic: immutable,
        descriptorPaths: const [],
        delegate: delegate,
      );

      final response = await immutableObject.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: blueZGattCharacteristicInterface,
          name: 'ReadValue',
          values: [_options(offset: 3)],
        ),
      );

      expect(response, isA<DBusMethodErrorResponse>());
      expect(
        (response as DBusMethodErrorResponse).errorName,
        'org.bluez.Error.InvalidOffset',
      );
    });
  });

  test('central identity is decoded from a BlueZ device path', () {
    final central = CentralImpl.fromDevicePath(
      DBusObjectPath('/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF'),
      mtu: 247,
    );
    expect(central.address, 'AA:BB:CC:DD:EE:FF');
    expect(central.uuid.toString(), '00000000-0000-0000-0000-aabbccddeeff');
    expect(central.mtu, 247);
  });
}

DBusDict _options({int offset = 0, int mtu = 23, String type = 'request'}) =>
    DBusDict.stringVariant({
      'device': DBusObjectPath('/org/bluez/hci0/dev_12_34_56_78_9A_BC'),
      'offset': DBusUint16(offset),
      'mtu': DBusUint16(mtu),
      'type': DBusString(type),
    });

final class _Delegate implements BlueZGattDelegate {
  final lastCentral = CentralImpl.fromDevicePath(
    DBusObjectPath('/org/bluez/hci0/dev_12_34_56_78_9A_BC'),
  );
  int? lastOffset;
  Uint8List? lastValue;
  GATTCharacteristicWriteType? lastWriteType;
  DBusMethodResponse writeResponse = DBusMethodSuccessResponse();
  final notificationStates = <bool>[];

  @override
  CentralImpl centralFromOptions(Map<String, DBusValue> options) {
    final path = options['device']! as DBusObjectPath;
    final mtu = (options['mtu']! as DBusUint16).value;
    final decoded = CentralImpl.fromDevicePath(path, mtu: mtu);
    lastCentral.mtu = decoded.mtu;
    return lastCentral;
  }

  @override
  CentralImpl centralForNotification() => lastCentral;

  @override
  void notificationChanged(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    bool notifying,
  ) {
    notificationStates.add(notifying);
  }

  @override
  Future<DBusMethodResponse> readCharacteristic(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    int offset,
  ) async {
    lastOffset = offset;
    return DBusMethodSuccessResponse([
      dbusBytes([1, 2, 3]),
    ]);
  }

  @override
  Future<DBusMethodResponse> readDescriptor(
    CentralImpl central,
    MutableGATTDescriptorImpl descriptor,
    int offset,
  ) async => DBusMethodSuccessResponse([dbusBytes(const [])]);

  @override
  Future<DBusMethodResponse> writeCharacteristic(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    int offset,
    Uint8List value,
    GATTCharacteristicWriteType type,
  ) async {
    lastOffset = offset;
    lastValue = value;
    lastWriteType = type;
    return writeResponse;
  }

  @override
  Future<DBusMethodResponse> writeDescriptor(
    CentralImpl central,
    MutableGATTDescriptorImpl descriptor,
    int offset,
    Uint8List value,
    GATTCharacteristicWriteType type,
  ) async => DBusMethodSuccessResponse();
}
