import 'package:flutter/foundation.dart';

enum LeaseHolderKind { user, task, session }

@immutable
class LeaseRequest {
  const LeaseRequest({
    required this.userId,
    required this.reason,
    required this.expectedDuration,
    required this.createdAt,
  });

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
    this.expiresAt,
    this.queue = const [],
  });

  final String deviceId;
  final LeaseHolderKind holderKind;

  /// userId / taskId / sessionId，取决于 [holderKind]。
  final String holderId;
  final String source;

  /// 随会话结束的租约为 null。
  final DateTime? expiresAt;
  final List<LeaseRequest> queue;
}
