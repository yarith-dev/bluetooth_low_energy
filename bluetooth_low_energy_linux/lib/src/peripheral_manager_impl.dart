import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';
import 'package:logging/logging.dart';

import 'bluez.dart';
import 'bluez_gatt_application.dart';
import 'central_impl.dart';
import 'gatt_request_impl.dart';

final _logger = Logger('PeripheralManager');

/// Linux BLE peripheral implementation backed by BlueZ's D-Bus GATT API.
final class PeripheralManagerImpl
    implements PeripheralManager, BlueZGattDelegate {
  PeripheralManagerImpl({BlueZClient? blueZClient, DBusClient? bus})
    : _blueZClient = blueZClient ?? BlueZClient(),
      _bus = bus ?? DBusClient.system() {
    _ready = _initialize();
  }

  static const _blueZService = 'org.bluez';
  static const _gattManagerInterface = 'org.bluez.GattManager1';
  static const _advertisingManagerInterface = 'org.bluez.LEAdvertisingManager1';
  static const _deviceInterface = 'org.bluez.Device1';
  static const _applicationBasePath = '/dev/zeekr/bluetooth_low_energy';

  final BlueZClient _blueZClient;
  final DBusClient _bus;
  late final Future<void> _ready;
  StreamSubscription<List<String>>? _adapterStateSubscription;
  StreamSubscription<DBusSignal>? _blueZSignalSubscription;

  final _stateChangedController =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final _connectionStateChangedController =
      StreamController<CentralConnectionStateChangedEventArgs>.broadcast();
  final _mtuChangedController =
      StreamController<CentralMTUChangedEventArgs>.broadcast();
  final _characteristicReadRequestedController =
      StreamController<GATTCharacteristicReadRequestedEventArgs>.broadcast();
  final _characteristicWriteRequestedController =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final _characteristicNotifyStateChangedController =
      StreamController<
        GATTCharacteristicNotifyStateChangedEventArgs
      >.broadcast();
  final _descriptorReadRequestedController =
      StreamController<GATTDescriptorReadRequestedEventArgs>.broadcast();
  final _descriptorWriteRequestedController =
      StreamController<GATTDescriptorWriteRequestedEventArgs>.broadcast();

  final Set<MutableGATTServiceImpl> _services =
      LinkedHashSet<MutableGATTServiceImpl>.identity();
  final _knownCentrals = <String, CentralImpl>{};
  final _connectedCentralAddresses = <String>{};
  final _pendingRequests = <int, PendingGATTRequest>{};
  var _nextRequestId = 0;
  var _nextApplicationId = 0;

  BluetoothLowEnergyState _state = BluetoothLowEnergyState.unknown;
  DBusObjectPath? _adapterPath;
  BlueZAdapter? _adapter;
  BlueZGattApplication? _application;
  BlueZAdvertisement? _advertisement;
  CentralImpl? _lastCentral;
  CentralImpl? _lastConnectedCentralCandidate;

  @override
  BluetoothLowEnergyState get state => _state;

  set _currentState(BluetoothLowEnergyState value) {
    if (_state == value) return;
    _state = value;
    _stateChangedController.add(BluetoothLowEnergyStateChangedEventArgs(value));
  }

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateChangedController.stream;
  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged =>
      _connectionStateChangedController.stream;
  @override
  Stream<CentralMTUChangedEventArgs> get mtuChanged =>
      _mtuChangedController.stream;
  @override
  Stream<GATTCharacteristicReadRequestedEventArgs>
  get characteristicReadRequested =>
      _characteristicReadRequestedController.stream;
  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested =>
      _characteristicWriteRequestedController.stream;
  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged =>
      _characteristicNotifyStateChangedController.stream;
  @override
  Stream<GATTDescriptorReadRequestedEventArgs> get descriptorReadRequested =>
      _descriptorReadRequestedController.stream;
  @override
  Stream<GATTDescriptorWriteRequestedEventArgs> get descriptorWriteRequested =>
      _descriptorWriteRequestedController.stream;

  @override
  Future<bool> authorize() async {
    await _ready;
    return _state == BluetoothLowEnergyState.poweredOn;
  }

  @override
  Future<void> showAppSettings() => Future<void>.error(
    UnsupportedError('showAppSettings is not supported on Linux.'),
  );

  @override
  Future<void> addService(GATTService service) async {
    await _ready;
    if (service is! MutableGATTServiceImpl) throw TypeError();
    _services.add(service);
    await _rebuildApplication();
  }

  @override
  Future<void> removeService(GATTService service) async {
    await _ready;
    if (!_services.remove(service)) return;
    await _rebuildApplication();
  }

  @override
  Future<void> removeAllServices() async {
    await _ready;
    _services.clear();
    await _unregisterApplication();
  }

  @override
  Future<void> startAdvertising(
    Advertisement advertisement, {
    TXPowerLevel? txPowerLevel,
  }) async {
    await _ready;
    _requireReadyAdapter();
    await stopAdvertising();
    final adapter = _requireBlueZAdapter();
    late BlueZAdvertisement registered;
    registered = await adapter.advertisingManager.registerAdvertisement(
      type: BlueZAdvertisementType.peripheral,
      localName: advertisement.name ?? '',
      serviceUuids: advertisement.serviceUUIDs
          .map((uuid) => uuid.toString())
          .toList(growable: false),
      serviceData: {
        for (final entry in advertisement.serviceData.entries)
          BlueZUUID.fromString(entry.key.toString()): dbusBytes(entry.value),
      },
      manufacturerData: {
        for (final entry in advertisement.manufacturerSpecificData)
          BlueZManufacturerId(entry.id): dbusBytes(entry.data),
      },
      includeTxPower: txPowerLevel != null,
      includes:
          advertisement.includeDeviceNameInAdvertisement &&
              advertisement.name == null
          ? const ['local-name']
          : const [],
      onRelease: () async {
        if (identical(_advertisement, registered)) _advertisement = null;
      },
    );
    _advertisement = registered;
  }

  @override
  Future<void> stopAdvertising() async {
    await _ready;
    final advertisement = _advertisement;
    if (advertisement == null) return;
    _advertisement = null;
    try {
      await _requireBlueZAdapter().advertisingManager.unregisterAdvertisement(
        advertisement,
      );
    } on Object catch (error, stackTrace) {
      _logger.warning('stopAdvertising failed', error, stackTrace);
    }
  }

  @override
  Future<Central> getCentral(String address) async {
    await _ready;
    final normalized = address.toUpperCase();
    final known = _knownCentrals[normalized];
    if (known != null) return known;
    final adapter = _requireReadyAdapter();
    final central = CentralImpl(
      address: normalized,
      devicePath: DBusObjectPath(
        '${adapter.value}/dev_${normalized.replaceAll(':', '_')}',
      ),
    );
    _knownCentrals[normalized] = central;
    return central;
  }

  @override
  Future<List<Central>> retrieveConnectedCentrals() async {
    await _ready;
    return [
      for (final address in _connectedCentralAddresses)
        if (_knownCentrals[address] case final central?) central,
    ];
  }

  @override
  Future<void> disconnect(Central central) async {
    await _ready;
    if (central is! CentralImpl) throw TypeError();
    final object = DBusRemoteObject(
      _bus,
      name: _blueZService,
      path: central.devicePath,
    );
    await object.callMethod(
      _deviceInterface,
      'Disconnect',
      const [],
      replySignature: DBusSignature(''),
    );
  }

  @override
  Future<int> getMaximumNotifyLength(Central central) async {
    if (central is! CentralImpl) throw TypeError();
    return (central.mtu - 3).clamp(20, 512);
  }

  @override
  Future<void> respondReadRequestWithValue(
    GATTReadRequest request, {
    required Uint8List value,
  }) async {
    final pending = _readRequest(request);
    pending.complete(DBusMethodSuccessResponse([dbusBytes(value)]));
  }

  @override
  Future<void> respondReadRequestWithError(
    GATTReadRequest request, {
    required GATTError error,
  }) async {
    _readRequest(request).complete(_errorResponse(error));
  }

  @override
  Future<void> respondWriteRequest(GATTWriteRequest request) async {
    final pending = _writeRequest(request);
    if (pending.type == GATTCharacteristicWriteType.withoutResponse) return;
    pending.complete(DBusMethodSuccessResponse());
  }

  @override
  Future<void> respondWriteRequestWithError(
    GATTWriteRequest request, {
    required GATTError error,
  }) async {
    final pending = _writeRequest(request);
    if (pending.type == GATTCharacteristicWriteType.withoutResponse) return;
    pending.complete(_errorResponse(error));
  }

  @override
  Future<void> notifyCharacteristic(
    Central central,
    GATTCharacteristic characteristic, {
    required Uint8List value,
  }) async {
    await _ready;
    if (central is! CentralImpl ||
        characteristic is! MutableGATTCharacteristicImpl) {
      throw TypeError();
    }
    final object = _application?.characteristics[characteristic];
    if (object == null) {
      throw StateError('Characteristic is not published.');
    }
    await object.notify(value);
  }

  @override
  CentralImpl centralFromOptions(Map<String, DBusValue> options) {
    final device = options['device'];
    final path = device is DBusObjectPath
        ? device
        : DBusObjectPath('/org/bluez/unknown/dev_00_00_00_00_00_00');
    final mtuValue = options['mtu'];
    final reportedMtu = switch (mtuValue) {
      DBusUint16() => mtuValue.value,
      DBusUint32() => mtuValue.value,
      _ => null,
    };
    final candidate = CentralImpl.fromDevicePath(path);
    final oldMtu = _knownCentrals[candidate.address]?.mtu;
    candidate.mtu = reportedMtu ?? oldMtu ?? 23;
    final central = _rememberCentral(candidate);
    _lastCentral = central;
    if (oldMtu != null && reportedMtu != null && oldMtu != reportedMtu) {
      _mtuChangedController.add(
        CentralMTUChangedEventArgs(central, reportedMtu),
      );
    }
    return central;
  }

  @override
  CentralImpl centralForNotification() => _rememberCentral(
    _lastCentral ??
        _lastConnectedCentralCandidate ??
        CentralImpl.fromDevicePath(
          DBusObjectPath('/org/bluez/unknown/dev_00_00_00_00_00_00'),
        ),
  );

  @override
  Future<DBusMethodResponse> readCharacteristic(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    int offset,
  ) {
    final request = GATTReadRequestImpl(
      id: ++_nextRequestId,
      central: central,
      offset: offset,
    );
    _pendingRequests[request.id] = request;
    _characteristicReadRequestedController.add(
      GATTCharacteristicReadRequestedEventArgs(
        central,
        characteristic,
        request,
      ),
    );
    return _waitForResponse(request);
  }

  @override
  Future<DBusMethodResponse> writeCharacteristic(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    int offset,
    Uint8List value,
    GATTCharacteristicWriteType type,
  ) {
    final request = GATTWriteRequestImpl(
      id: ++_nextRequestId,
      central: central,
      offset: offset,
      value: value,
      type: type,
    );
    if (type == GATTCharacteristicWriteType.withResponse) {
      _pendingRequests[request.id] = request;
    }
    _characteristicWriteRequestedController.add(
      GATTCharacteristicWriteRequestedEventArgs(
        central,
        characteristic,
        request,
      ),
    );
    return type == GATTCharacteristicWriteType.withoutResponse
        ? Future.value(DBusMethodSuccessResponse())
        : _waitForResponse(request);
  }

  @override
  Future<DBusMethodResponse> readDescriptor(
    CentralImpl central,
    MutableGATTDescriptorImpl descriptor,
    int offset,
  ) {
    final request = GATTReadRequestImpl(
      id: ++_nextRequestId,
      central: central,
      offset: offset,
    );
    _pendingRequests[request.id] = request;
    _descriptorReadRequestedController.add(
      GATTDescriptorReadRequestedEventArgs(central, descriptor, request),
    );
    return _waitForResponse(request);
  }

  @override
  Future<DBusMethodResponse> writeDescriptor(
    CentralImpl central,
    MutableGATTDescriptorImpl descriptor,
    int offset,
    Uint8List value,
    GATTCharacteristicWriteType type,
  ) {
    final request = GATTWriteRequestImpl(
      id: ++_nextRequestId,
      central: central,
      offset: offset,
      value: value,
      type: type,
    );
    if (type == GATTCharacteristicWriteType.withResponse) {
      _pendingRequests[request.id] = request;
    }
    _descriptorWriteRequestedController.add(
      GATTDescriptorWriteRequestedEventArgs(central, descriptor, request),
    );
    return type == GATTCharacteristicWriteType.withoutResponse
        ? Future.value(DBusMethodSuccessResponse())
        : _waitForResponse(request);
  }

  @override
  void notificationChanged(
    CentralImpl central,
    MutableGATTCharacteristicImpl characteristic,
    bool notifying,
  ) {
    _characteristicNotifyStateChangedController.add(
      GATTCharacteristicNotifyStateChangedEventArgs(
        central,
        characteristic,
        notifying,
      ),
    );
  }

  Future<void> _initialize() async {
    try {
      await _blueZClient.connect();
      final selected = await _findPeripheralAdapter();
      if (selected == null) {
        _currentState = BluetoothLowEnergyState.unsupported;
        return;
      }
      BlueZAdapter? adapter;
      for (final candidate in _blueZClient.adapters) {
        if (candidate.address.toUpperCase() == selected.address) {
          adapter = candidate;
          break;
        }
      }
      if (adapter == null) {
        _currentState = BluetoothLowEnergyState.unsupported;
        return;
      }
      final selectedAdapter = adapter;
      _adapterPath = selected.path;
      _adapter = selectedAdapter;
      _currentState = selectedAdapter.state;
      _adapterStateSubscription = selectedAdapter.propertiesChanged.listen((_) {
        _currentState = selectedAdapter.state;
      });
      final objectManager = DBusRemoteObjectManager(
        _bus,
        name: _blueZService,
        path: DBusObjectPath('/'),
      );
      _blueZSignalSubscription = objectManager.signals.listen(
        _handleBlueZSignal,
      );
    } on Object catch (error, stackTrace) {
      _currentState = BluetoothLowEnergyState.unsupported;
      _logger.severe('initialize failed', error, stackTrace);
    }
  }

  Future<({DBusObjectPath path, String address})?>
  _findPeripheralAdapter() async {
    final objects = await DBusRemoteObjectManager(
      _bus,
      name: _blueZService,
      path: DBusObjectPath('/'),
    ).getManagedObjects();
    for (final entry in objects.entries) {
      final interfaces = entry.value.keys;
      if (interfaces.contains('org.bluez.Adapter1') &&
          interfaces.contains(_gattManagerInterface) &&
          interfaces.contains(_advertisingManagerInterface)) {
        final address = entry.value['org.bluez.Adapter1']?['Address'];
        if (address is DBusString) {
          return (path: entry.key, address: address.value.toUpperCase());
        }
      }
    }
    return null;
  }

  DBusObjectPath _requireReadyAdapter() {
    final path = _adapterPath;
    if (path == null) {
      throw UnsupportedError(
        'The Bluetooth adapter does not expose BlueZ GATT and advertising managers.',
      );
    }
    if (_state != BluetoothLowEnergyState.poweredOn) {
      throw StateError('Bluetooth is not powered on.');
    }
    return path;
  }

  BlueZAdapter _requireBlueZAdapter() {
    _requireReadyAdapter();
    final adapter = _adapter;
    if (adapter == null) {
      throw UnsupportedError('The selected BlueZ adapter is unavailable.');
    }
    return adapter;
  }

  Future<void> _rebuildApplication() async {
    final adapter = _requireReadyAdapter();
    await _unregisterApplication();
    if (_services.isEmpty) return;

    final rootPath = DBusObjectPath(
      '$_applicationBasePath/app${++_nextApplicationId}',
    );
    final root = DBusObject(rootPath, isObjectManager: true);
    final objects = <DBusObject>[root];
    final characteristicObjects =
        <MutableGATTCharacteristicImpl, LinuxGattCharacteristic>{};
    final allServices = _flattenServices(_services);
    final servicePaths = <MutableGATTServiceImpl, DBusObjectPath>{};
    for (
      var serviceIndex = 0;
      serviceIndex < allServices.length;
      serviceIndex++
    ) {
      servicePaths[allServices[serviceIndex]] = DBusObjectPath(
        '${rootPath.value}/service$serviceIndex',
      );
    }
    for (final service in allServices) {
      final servicePath = servicePaths[service]!;
      objects.add(
        LinuxGattService(
          path: servicePath,
          service: service,
          includedPaths: [
            for (final included in service.includedServices)
              servicePaths[included]!,
          ],
        ),
      );
      for (
        var characteristicIndex = 0;
        characteristicIndex < service.characteristics.length;
        characteristicIndex++
      ) {
        final characteristic = service.characteristics[characteristicIndex];
        final characteristicPath = DBusObjectPath(
          '${servicePath.value}/char$characteristicIndex',
        );
        final descriptorPaths = <DBusObjectPath>[];
        for (
          var descriptorIndex = 0;
          descriptorIndex < characteristic.descriptors.length;
          descriptorIndex++
        ) {
          descriptorPaths.add(
            DBusObjectPath('${characteristicPath.value}/desc$descriptorIndex'),
          );
        }
        final characteristicObject = LinuxGattCharacteristic(
          path: characteristicPath,
          servicePath: servicePath,
          characteristic: characteristic,
          descriptorPaths: descriptorPaths,
          delegate: this,
        );
        objects.add(characteristicObject);
        characteristicObjects[characteristic] = characteristicObject;
        for (
          var descriptorIndex = 0;
          descriptorIndex < characteristic.descriptors.length;
          descriptorIndex++
        ) {
          objects.add(
            LinuxGattDescriptor(
              path: descriptorPaths[descriptorIndex],
              characteristicPath: characteristicPath,
              descriptor: characteristic.descriptors[descriptorIndex],
              delegate: this,
            ),
          );
        }
      }
    }

    for (final object in objects) {
      await _bus.registerObject(object);
    }
    final application = BlueZGattApplication(
      root: root,
      services: allServices,
      objects: objects,
      characteristics: characteristicObjects,
    );
    _application = application;
    try {
      await DBusRemoteObject(
        _bus,
        name: _blueZService,
        path: adapter,
      ).callMethod(
        _gattManagerInterface,
        'RegisterApplication',
        [rootPath, DBusDict.stringVariant(const {})],
        replySignature: DBusSignature(''),
      );
    } on Object {
      _application = null;
      for (final object in objects.reversed) {
        await _bus.unregisterObject(object);
      }
      rethrow;
    }
  }

  Future<void> _unregisterApplication() async {
    final application = _application;
    if (application == null) return;
    _application = null;
    final adapter = _adapterPath;
    if (adapter != null) {
      try {
        await DBusRemoteObject(
          _bus,
          name: _blueZService,
          path: adapter,
        ).callMethod(
          _gattManagerInterface,
          'UnregisterApplication',
          [application.root.path],
          replySignature: DBusSignature(''),
        );
      } on Object catch (error, stackTrace) {
        _logger.warning('UnregisterApplication failed', error, stackTrace);
      }
    }
    for (final object in application.objects.reversed) {
      try {
        await _bus.unregisterObject(object);
      } on Object catch (error, stackTrace) {
        _logger.warning('D-Bus object cleanup failed', error, stackTrace);
      }
    }
  }

  List<MutableGATTServiceImpl> _flattenServices(
    Iterable<MutableGATTServiceImpl> roots,
  ) {
    final result = <MutableGATTServiceImpl>[];
    final seen = HashSet<MutableGATTServiceImpl>.identity();
    void visit(MutableGATTServiceImpl service) {
      if (!seen.add(service)) return;
      for (final included in service.includedServices) {
        visit(included);
      }
      result.add(service);
    }

    for (final service in roots) {
      visit(service);
    }
    return result;
  }

  CentralImpl _rememberCentral(CentralImpl central) {
    final existing = _knownCentrals[central.address];
    final remembered = existing ?? central;
    if (existing != null && central.mtu != existing.mtu) {
      existing.mtu = central.mtu;
    }
    _knownCentrals[remembered.address] = remembered;
    _lastCentral = remembered;
    if (_connectedCentralAddresses.add(remembered.address)) {
      _connectionStateChangedController.add(
        CentralConnectionStateChangedEventArgs(
          remembered,
          ConnectionState.connected,
        ),
      );
    }
    return remembered;
  }

  void _handleBlueZSignal(DBusSignal signal) {
    if (signal is! DBusPropertiesChangedSignal ||
        signal.propertiesInterface != _deviceInterface ||
        !signal.changedProperties.containsKey('Connected')) {
      return;
    }
    final adapter = _adapterPath;
    if (adapter == null || !signal.path.value.startsWith('${adapter.value}/')) {
      return;
    }
    final central = CentralImpl.fromDevicePath(signal.path);
    final connected =
        signal.changedProperties['Connected']?.asBoolean() ?? false;
    if (connected) {
      // BlueZ reports every device connected through the adapter. Keep this as
      // a candidate for a notify-only GATT client, but do not claim it as a
      // MeowShare connection until it accesses this application's service.
      _lastConnectedCentralCandidate = central;
      return;
    }
    if (_lastConnectedCentralCandidate == central) {
      _lastConnectedCentralCandidate = null;
    }
    final known = _knownCentrals[central.address] ?? central;
    if (_connectedCentralAddresses.remove(known.address)) {
      _connectionStateChangedController.add(
        CentralConnectionStateChangedEventArgs(
          known,
          ConnectionState.disconnected,
        ),
      );
    }
    if (_lastCentral == known) {
      _lastCentral = null;
    }
  }

  Future<DBusMethodResponse> _waitForResponse(PendingGATTRequest request) =>
      request.response.future
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => DBusMethodErrorResponse('org.bluez.Error.Failed', [
              DBusString('Application response timed out'),
            ]),
          )
          .whenComplete(() => _pendingRequests.remove(request.id));

  GATTReadRequestImpl _readRequest(GATTReadRequest request) {
    if (request is! GATTReadRequestImpl ||
        _pendingRequests[request.id] != request) {
      throw StateError('Read request is no longer pending.');
    }
    return request;
  }

  GATTWriteRequestImpl _writeRequest(GATTWriteRequest request) {
    if (request is! GATTWriteRequestImpl) throw TypeError();
    if (request.type == GATTCharacteristicWriteType.withResponse &&
        _pendingRequests[request.id] != request) {
      throw StateError('Write request is no longer pending.');
    }
    return request;
  }

  DBusMethodErrorResponse _errorResponse(GATTError error) {
    final name = switch (error) {
      GATTError.readNotPermitted ||
      GATTError.writeNotPermitted => 'org.bluez.Error.NotPermitted',
      GATTError.invalidOffset => 'org.bluez.Error.InvalidOffset',
      GATTError.insufficientAuthentication ||
      GATTError.insufficientAuthorization ||
      GATTError.insufficientEncryption ||
      GATTError.insufficientEncryptionKeySize =>
        'org.bluez.Error.NotAuthorized',
      GATTError.requestNotSupported ||
      GATTError.attributeNotFound ||
      GATTError.unsupportedGroupType => 'org.bluez.Error.NotSupported',
      GATTError.invalidPDU || GATTError.invalidAttributeValueLength =>
        'org.bluez.Error.InvalidValueLength',
      _ => 'org.bluez.Error.Failed',
    };
    return DBusMethodErrorResponse(name);
  }

  /// Releases the D-Bus clients and stream controllers owned by this manager.
  /// Applications normally keep the process-wide manager for their lifetime;
  /// this hook is useful to deterministic Linux integration tests.
  Future<void> dispose() async {
    await _ready;
    await stopAdvertising();
    await _unregisterApplication();
    await _adapterStateSubscription?.cancel();
    await _blueZSignalSubscription?.cancel();
    await _blueZClient.close();
    await _bus.close();
    await Future.wait([
      _stateChangedController.close(),
      _connectionStateChangedController.close(),
      _mtuChangedController.close(),
      _characteristicReadRequestedController.close(),
      _characteristicWriteRequestedController.close(),
      _characteristicNotifyStateChangedController.close(),
      _descriptorReadRequestedController.close(),
      _descriptorWriteRequestedController.close(),
    ]);
  }
}

final class PeripheralManagerChannelImpl extends PeripheralManagerChannel {
  @override
  PeripheralManager create({bool showPowerAlert = true}) =>
      PeripheralManagerImpl();
}
