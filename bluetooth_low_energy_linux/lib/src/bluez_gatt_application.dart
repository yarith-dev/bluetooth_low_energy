import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:dbus/dbus.dart';

import 'central_impl.dart';

const blueZGattServiceInterface = 'org.bluez.GattService1';
const blueZGattCharacteristicInterface = 'org.bluez.GattCharacteristic1';
const blueZGattDescriptorInterface = 'org.bluez.GattDescriptor1';

DBusArray dbusBytes(Iterable<int> value) =>
    DBusArray(DBusSignature('y'), value.map((byte) => DBusByte(byte)));

abstract interface class BlueZGattDelegate {
  CentralImpl centralFromOptions(Map<String, DBusValue> options);
  CentralImpl centralForNotification();

  Future<DBusMethodResponse> readCharacteristic(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    int offset,
  );

  Future<DBusMethodResponse> writeCharacteristic(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    int offset,
    Uint8List value,
    GATTCharacteristicWriteType type,
  );

  Future<DBusMethodResponse> readDescriptor(
    CentralImpl central,
    MutableGATTDescriptorImpl descriptor,
    int offset,
  );

  Future<DBusMethodResponse> writeDescriptor(
    CentralImpl central,
    MutableGATTDescriptorImpl descriptor,
    int offset,
    Uint8List value,
    GATTCharacteristicWriteType type,
  );

  void notificationChanged(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    bool notifying,
  );
}

final class BlueZGattApplication {
  BlueZGattApplication({
    required this.root,
    required this.services,
    required this.objects,
    required this.characteristics,
  });

  final DBusObject root;
  final List<MutableGATTServiceImpl> services;
  final List<DBusObject> objects;
  final Map<MutableGATTCharacteristicImpl, LinuxGattCharacteristic>
  characteristics;
}

final class LinuxGattService extends DBusObject {
  LinuxGattService({
    required DBusObjectPath path,
    required this.service,
    required this.includedPaths,
  }) : super(path);

  final MutableGATTServiceImpl service;
  final List<DBusObjectPath> includedPaths;

  Map<String, DBusValue> get _properties => {
    'UUID': DBusString(service.uuid.toString()),
    'Primary': DBusBoolean(service.isPrimary),
    if (includedPaths.isNotEmpty)
      'Includes': DBusArray(DBusSignature('o'), includedPaths),
  };

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    blueZGattServiceInterface: _properties,
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      blueZGattServiceInterface,
      properties: [
        DBusIntrospectProperty(
          'UUID',
          DBusSignature('s'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Primary',
          DBusSignature('b'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Includes',
          DBusSignature('ao'),
          access: DBusPropertyAccess.read,
        ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != blueZGattServiceInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == blueZGattServiceInterface
      ? DBusGetAllPropertiesResponse(_properties)
      : DBusMethodErrorResponse.unknownInterface();
}

final class LinuxGattCharacteristic extends DBusObject {
  LinuxGattCharacteristic({
    required DBusObjectPath path,
    required this.servicePath,
    required this.characteristic,
    required this.descriptorPaths,
    required this.delegate,
  }) : _value = characteristic is ImmutableGATTCharacteristicImpl
           ? Uint8List.fromList(characteristic.value)
           : Uint8List(0),
       super(path);

  final DBusObjectPath servicePath;
  final MutableGATTCharacteristicImpl characteristic;
  final List<DBusObjectPath> descriptorPaths;
  final BlueZGattDelegate delegate;
  Uint8List _value;
  bool _notifying = false;

  bool get notifying => _notifying;

  Map<String, DBusValue> get _properties => {
    'UUID': DBusString(characteristic.uuid.toString()),
    'Service': servicePath,
    'Value': dbusBytes(_value),
    'Flags': DBusArray.string(_characteristicFlags(characteristic)),
    'Notifying': DBusBoolean(_notifying),
    if (descriptorPaths.isNotEmpty)
      'Descriptors': DBusArray(DBusSignature('o'), descriptorPaths),
  };

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    blueZGattCharacteristicInterface: _properties,
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      blueZGattCharacteristicInterface,
      methods: [
        DBusIntrospectMethod(
          'ReadValue',
          args: [
            DBusIntrospectArgument(
              DBusSignature('a{sv}'),
              DBusArgumentDirection.in_,
              name: 'options',
            ),
            DBusIntrospectArgument(
              DBusSignature('ay'),
              DBusArgumentDirection.out,
              name: 'value',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'WriteValue',
          args: [
            DBusIntrospectArgument(
              DBusSignature('ay'),
              DBusArgumentDirection.in_,
              name: 'value',
            ),
            DBusIntrospectArgument(
              DBusSignature('a{sv}'),
              DBusArgumentDirection.in_,
              name: 'options',
            ),
          ],
        ),
        DBusIntrospectMethod('StartNotify'),
        DBusIntrospectMethod('StopNotify'),
      ],
      properties: [
        DBusIntrospectProperty(
          'UUID',
          DBusSignature('s'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Service',
          DBusSignature('o'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Value',
          DBusSignature('ay'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Flags',
          DBusSignature('as'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Notifying',
          DBusSignature('b'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Descriptors',
          DBusSignature('ao'),
          access: DBusPropertyAccess.read,
        ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != blueZGattCharacteristicInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'ReadValue':
        if (methodCall.signature != DBusSignature('a{sv}')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        if (!characteristic.properties.contains(
          GATTCharacteristicProperty.read,
        )) {
          return DBusMethodErrorResponse('org.bluez.Error.NotPermitted');
        }
        final options = methodCall.values.single.asStringVariantDict();
        final offset = _optionInt(options, 'offset');
        if (characteristic is ImmutableGATTCharacteristicImpl) {
          if (offset > _value.length) {
            return DBusMethodErrorResponse('org.bluez.Error.InvalidOffset');
          }
          return DBusMethodSuccessResponse([dbusBytes(_value.sublist(offset))]);
        }
        return delegate.readCharacteristic(
          delegate.centralFromOptions(options),
          characteristic,
          offset,
        );
      case 'WriteValue':
        if (methodCall.signature != DBusSignature('aya{sv}')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        final bytes = Uint8List.fromList(
          methodCall.values[0].asByteArray().toList(),
        );
        final options = methodCall.values[1].asStringVariantDict();
        final type = _writeType(options, characteristic);
        final allowed = switch (type) {
          GATTCharacteristicWriteType.withResponse =>
            characteristic.properties.contains(
              GATTCharacteristicProperty.write,
            ),
          GATTCharacteristicWriteType.withoutResponse =>
            characteristic.properties.contains(
              GATTCharacteristicProperty.writeWithoutResponse,
            ),
        };
        if (!allowed) {
          return DBusMethodErrorResponse('org.bluez.Error.NotPermitted');
        }
        final offset = _optionInt(options, 'offset');
        final response = await delegate.writeCharacteristic(
          delegate.centralFromOptions(options),
          characteristic,
          offset,
          bytes,
          type,
        );
        if (response is DBusMethodSuccessResponse) {
          _value = _replaceBytes(_value, bytes, offset);
        }
        return response;
      case 'StartNotify':
        if (methodCall.values.isNotEmpty) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        if (!characteristic.properties.any(
          (property) =>
              property == GATTCharacteristicProperty.notify ||
              property == GATTCharacteristicProperty.indicate,
        )) {
          return DBusMethodErrorResponse('org.bluez.Error.NotSupported');
        }
        if (_notifying) {
          return DBusMethodErrorResponse('org.bluez.Error.InProgress');
        }
        _notifying = true;
        final central = delegate.centralForNotification();
        delegate.notificationChanged(central, characteristic, true);
        await emitPropertiesChanged(
          blueZGattCharacteristicInterface,
          changedProperties: {'Notifying': DBusBoolean(true)},
        );
        return DBusMethodSuccessResponse();
      case 'StopNotify':
        if (methodCall.values.isNotEmpty) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        if (!_notifying) return DBusMethodSuccessResponse();
        _notifying = false;
        final central = delegate.centralForNotification();
        delegate.notificationChanged(central, characteristic, false);
        await emitPropertiesChanged(
          blueZGattCharacteristicInterface,
          changedProperties: {'Notifying': DBusBoolean(false)},
        );
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  Future<void> notify(Uint8List value) async {
    _value = Uint8List.fromList(value);
    if (!_notifying) return;
    await emitPropertiesChanged(
      blueZGattCharacteristicInterface,
      changedProperties: {'Value': dbusBytes(value)},
    );
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != blueZGattCharacteristicInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == blueZGattCharacteristicInterface
      ? DBusGetAllPropertiesResponse(_properties)
      : DBusMethodErrorResponse.unknownInterface();
}

final class LinuxGattDescriptor extends DBusObject {
  LinuxGattDescriptor({
    required DBusObjectPath path,
    required this.characteristicPath,
    required this.descriptor,
    required this.delegate,
  }) : _value = descriptor is ImmutableGATTDescriptorImpl
           ? Uint8List.fromList(descriptor.value)
           : Uint8List(0),
       super(path);

  final DBusObjectPath characteristicPath;
  final MutableGATTDescriptorImpl descriptor;
  final BlueZGattDelegate delegate;
  Uint8List _value;

  Map<String, DBusValue> get _properties => {
    'UUID': DBusString(descriptor.uuid.toString()),
    'Characteristic': characteristicPath,
    'Value': dbusBytes(_value),
    'Flags': DBusArray.string(_descriptorFlags(descriptor)),
  };

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    blueZGattDescriptorInterface: _properties,
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      blueZGattDescriptorInterface,
      methods: [
        DBusIntrospectMethod(
          'ReadValue',
          args: [
            DBusIntrospectArgument(
              DBusSignature('a{sv}'),
              DBusArgumentDirection.in_,
              name: 'options',
            ),
            DBusIntrospectArgument(
              DBusSignature('ay'),
              DBusArgumentDirection.out,
              name: 'value',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'WriteValue',
          args: [
            DBusIntrospectArgument(
              DBusSignature('ay'),
              DBusArgumentDirection.in_,
              name: 'value',
            ),
            DBusIntrospectArgument(
              DBusSignature('a{sv}'),
              DBusArgumentDirection.in_,
              name: 'options',
            ),
          ],
        ),
      ],
      properties: [
        DBusIntrospectProperty(
          'UUID',
          DBusSignature('s'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Characteristic',
          DBusSignature('o'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Value',
          DBusSignature('ay'),
          access: DBusPropertyAccess.read,
        ),
        DBusIntrospectProperty(
          'Flags',
          DBusSignature('as'),
          access: DBusPropertyAccess.read,
        ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != blueZGattDescriptorInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'ReadValue':
        if (methodCall.signature != DBusSignature('a{sv}')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        if (!descriptor.permissions.any(
          (permission) =>
              permission == GATTCharacteristicPermission.read ||
              permission == GATTCharacteristicPermission.readEncrypted,
        )) {
          return DBusMethodErrorResponse('org.bluez.Error.NotPermitted');
        }
        final options = methodCall.values.single.asStringVariantDict();
        final offset = _optionInt(options, 'offset');
        if (descriptor is ImmutableGATTDescriptorImpl) {
          if (offset > _value.length) {
            return DBusMethodErrorResponse('org.bluez.Error.InvalidOffset');
          }
          return DBusMethodSuccessResponse([dbusBytes(_value.sublist(offset))]);
        }
        return delegate.readDescriptor(
          delegate.centralFromOptions(options),
          descriptor,
          offset,
        );
      case 'WriteValue':
        if (methodCall.signature != DBusSignature('aya{sv}')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        final bytes = Uint8List.fromList(
          methodCall.values[0].asByteArray().toList(),
        );
        final options = methodCall.values[1].asStringVariantDict();
        if (!descriptor.permissions.any(
          (permission) =>
              permission == GATTCharacteristicPermission.write ||
              permission == GATTCharacteristicPermission.writeEncrypted,
        )) {
          return DBusMethodErrorResponse('org.bluez.Error.NotPermitted');
        }
        final offset = _optionInt(options, 'offset');
        final type = _writeTypeFromOptions(options);
        final response = await delegate.writeDescriptor(
          delegate.centralFromOptions(options),
          descriptor,
          offset,
          bytes,
          type,
        );
        if (response is DBusMethodSuccessResponse) {
          _value = _replaceBytes(_value, bytes, offset);
        }
        return response;
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != blueZGattDescriptorInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == blueZGattDescriptorInterface
      ? DBusGetAllPropertiesResponse(_properties)
      : DBusMethodErrorResponse.unknownInterface();
}

int _optionInt(Map<String, DBusValue> options, String key) {
  final value = options[key];
  return switch (value) {
    DBusByte() => value.value,
    DBusUint16() => value.value,
    DBusUint32() => value.value,
    DBusUint64() => value.value,
    _ => 0,
  };
}

Uint8List _replaceBytes(Uint8List current, Uint8List replacement, int offset) {
  if (offset <= 0) return Uint8List.fromList(replacement);
  final size = offset + replacement.length;
  final value = Uint8List(size > current.length ? size : current.length);
  value.setRange(0, current.length, current);
  value.setRange(offset, size, replacement);
  return value;
}

GATTCharacteristicWriteType _writeType(
  Map<String, DBusValue> options,
  MutableGATTCharacteristicImpl characteristic,
) {
  final explicit = options['type'];
  if (explicit is DBusString) {
    return explicit.value == 'command'
        ? GATTCharacteristicWriteType.withoutResponse
        : GATTCharacteristicWriteType.withResponse;
  }
  final onlyWithoutResponse =
      characteristic.properties.contains(
        GATTCharacteristicProperty.writeWithoutResponse,
      ) &&
      !characteristic.properties.contains(GATTCharacteristicProperty.write);
  return onlyWithoutResponse
      ? GATTCharacteristicWriteType.withoutResponse
      : GATTCharacteristicWriteType.withResponse;
}

GATTCharacteristicWriteType _writeTypeFromOptions(
  Map<String, DBusValue> options,
) =>
    options['type'] is DBusString &&
        (options['type']! as DBusString).value == 'command'
    ? GATTCharacteristicWriteType.withoutResponse
    : GATTCharacteristicWriteType.withResponse;

List<String> _characteristicFlags(MutableGATTCharacteristicImpl value) {
  final flags = <String>{};
  final encryptRead = value.permissions.contains(
    GATTCharacteristicPermission.readEncrypted,
  );
  final encryptWrite = value.permissions.contains(
    GATTCharacteristicPermission.writeEncrypted,
  );
  for (final property in value.properties) {
    flags.add(switch (property) {
      GATTCharacteristicProperty.read => encryptRead ? 'encrypt-read' : 'read',
      GATTCharacteristicProperty.write =>
        encryptWrite ? 'encrypt-write' : 'write',
      GATTCharacteristicProperty.writeWithoutResponse =>
        'write-without-response',
      GATTCharacteristicProperty.notify => 'notify',
      GATTCharacteristicProperty.indicate => 'indicate',
    });
  }
  if (encryptWrite &&
      value.properties.contains(
        GATTCharacteristicProperty.writeWithoutResponse,
      )) {
    flags.add('encrypt-write');
  }
  return flags.toList(growable: false);
}

List<String> _descriptorFlags(MutableGATTDescriptorImpl value) {
  final flags = <String>{};
  for (final permission in value.permissions) {
    switch (permission) {
      case GATTCharacteristicPermission.read:
        flags.add('read');
      case GATTCharacteristicPermission.readEncrypted:
        flags.add('encrypt-read');
      case GATTCharacteristicPermission.write:
        flags.add('write');
      case GATTCharacteristicPermission.writeEncrypted:
        flags.add('encrypt-write');
    }
  }
  return flags.toList(growable: false);
}
