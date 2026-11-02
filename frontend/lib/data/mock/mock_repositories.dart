import 'dart:async';

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';

/// 内存中的可观察值：订阅时先发当前值，之后推送变化。
class _Store<T> {
  _Store(this._value);

  T _value;
  final _changes = StreamController<T>.broadcast();

  T get value => _value;

  set value(T v) {
    _value = v;
    _changes.add(v);
  }

  Stream<T> watch() async* {
    yield _value;
    yield* _changes.stream;
  }
}

class MockDeviceRepository implements DeviceRepository {
  final _devices = _Store<List<Device>>(MockData.devices);
  final _groups = _Store<List<DeviceGroup>>(MockData.groups);

  @override
  Stream<List<Device>> watchDevices() => _devices.watch();

  @override
  Stream<List<DeviceGroup>> watchGroups() => _groups.watch();
}

class MockAlertRepository implements AlertRepository {
  final _alerts = _Store<List<Alert>>(MockData.alerts);

  @override
  Stream<List<Alert>> watchAlerts() => _alerts.watch();
}

class MockFleetRepository implements FleetRepository {
  final _sessions = _Store<List<FleetSession>>(MockData.sessions);

  @override
  Stream<List<FleetSession>> watchSessions() => _sessions.watch();
}

class MockLeaseRepository implements LeaseRepository {
  final _leases = _Store<List<Lease>>(MockData.leases);

  @override
  Stream<List<Lease>> watchLeases() => _leases.watch();
}

class MockMemberRepository implements MemberRepository {
  final _members = _Store<List<Member>>(MockData.members);

  @override
  Stream<List<Member>> watchMembers() => _members.watch();

  @override
  Stream<Member> watchCurrentUser() => _members.watch().map((m) => m.first);
}
