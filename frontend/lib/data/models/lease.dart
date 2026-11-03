import 'package:flutter/foundation.dart';

enum LeaseHolderKind { user, task, session }

@immutable
class LeaseRequest {
  const LeaseRequest({
    required this.id,
    required this.userId,
    required this.reason,
    required this.expectedDuration,
    required this.createdAt,
  });

  /// `POST /lease-requests/{id}/approve · /deny` 用的申请 id。
  final String id;
  final String userId;
  final String reason;
  final Duration expectedDuration;
  final DateTime createdAt;
}

/// HANDOFF.md §6 Lease：同一时刻一台设备只有一个控制者（§8.2）。
@immutable
class Lease {
  const Lease({
    required this.deviceId,
    required this.holderKind,
    required this.holderId,
    required this.source,
    this.acquiredAt,
    this.expiresAt,
    this.queue = const [],
  });

  final String deviceId;
  final LeaseHolderKind holderKind;

  /// userId / taskId / sessionId，取决于 [holderKind]。
  final String holderId;
  final String source;

  /// 获得控制权的时间（「已控制 41 分钟」）。
  final DateTime? acquiredAt;

  /// 随会话结束的租约为 null。
  final DateTime? expiresAt;
  final List<LeaseRequest> queue;

  Lease copyWith({
    LeaseHolderKind? holderKind,
    String? holderId,
    String? source,
    DateTime? acquiredAt,
    DateTime? expiresAt,
    bool clearExpiry = false,
    List<LeaseRequest>? queue,
  }) => Lease(
    deviceId: deviceId,
    holderKind: holderKind ?? this.holderKind,
    holderId: holderId ?? this.holderId,
    source: source ?? this.source,
    acquiredAt: acquiredAt ?? this.acquiredAt,
    expiresAt: clearExpiry ? null : expiresAt ?? this.expiresAt,
    queue: queue ?? this.queue,
  );
}

/// `POST /devices/{id}/lease/transfer` 的目标：成员或自动任务。
@immutable
class LeaseTarget {
  const LeaseTarget.user(this.id) : kind = LeaseHolderKind.user;
  const LeaseTarget.task(this.id) : kind = LeaseHolderKind.task;

  final LeaseHolderKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is LeaseTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// 控制权操作失败（API 错误码 403 forbidden / 409 conflict）。
class LeaseException implements Exception {
  const LeaseException(this.code, this.message);

  /// `forbidden` 或 `conflict`。
  final String code;
  final String message;

  @override
  String toString() => message;
}
