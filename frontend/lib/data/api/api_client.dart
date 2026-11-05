import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 应用版本，写进请求头 `X-Client`（与 pubspec.yaml 的 version 保持一致）。
const appVersion = '1.0.0';

/// 请求头 `X-Client: macOS 1.0.0`：服务端写入审计日志「客户端」列和「已登录设备」。
///
/// 只能用 ASCII：dart:io 的 HttpHeaders 拒绝非 ASCII 的值（「·」会抛 FormatException），
/// 所以不能按 API.md 示例写成「macOS · 1.0.0」。
String clientHeader() {
  final platform = switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.android => 'Android',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
  return '$platform $appVersion';
}

/// 会话名（「设置 › 已登录设备」）：本机名，去掉 `.local`。
String deviceName() {
  if (kIsWeb) return 'Web';
  try {
    final host = Platform.localHostname;
    return host.endsWith('.local') ? host.substring(0, host.length - 6) : host;
  } on Object {
    return clientHeader().split(' ').first;
  }
}

/// 把登录页填写的服务器地址规范成 API 根地址（`…/api/v1`）。
///
/// 没写协议时：localhost、IP、`.local` 用 http（局域网部署），其余用 https。
/// 地址无效时返回 null。
Uri? apiBase(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) {
    final host = s.split(RegExp('[:/]')).first.toLowerCase();
    final local =
        host == 'localhost' ||
        host.endsWith('.local') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
    s = '${local ? 'http' : 'https'}://$s';
  }
  final uri = Uri.tryParse(s);
  if (uri == null ||
      uri.host.isEmpty ||
      !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return null;
  }
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (!path.endsWith('/api/v1')) path = '$path/api/v1';
  return uri.replace(path: path, query: null, fragment: null);
}

/// 服务器返回的错误（`{"error": {code, message}}`），或网络错误（[code] 为 `network`）。
class ApiException implements Exception {
  const ApiException(
    this.status,
    this.code,
    this.message, {
    this.deviceIds = const [],
  });

  /// HTTP 状态码；网络错误为 0。
  final int status;
  final String code;

  /// 给人看的中文，界面原样显示。
  final String message;

  /// 409 涉及的设备（前端据此标红）。
  final List<String> deviceIds;

  @override
  String toString() => message;
}

/// REST 客户端：`Authorization`、`X-Client`、JSON 编解码与错误格式。
class ApiClient {
  ApiClient({
    required this.base,
    this.token,
    http.Client? client,
    this.onUnauthorized,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri base;
  final String? token;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// 带令牌的请求收到 401（会话失效、被踢下线）时调用。
  final VoidCallback? onUnauthorized;

  Uri _uri(String path, [Map<String, String>? query]) => base.replace(
    path: '${base.path}$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    'Content-Type': 'application/json; charset=utf-8',
    'X-Client': clientHeader(),
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<Object?> get(String path, {Map<String, String>? query}) =>
      _send(() => _client.get(_uri(path, query), headers: _headers));

  Future<Object?> post(String path, [Object? body]) => _send(
    () => _client.post(
      _uri(path),
      headers: _headers,
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<Object?> patch(String path, Object body) => _send(
    () => _client.patch(_uri(path), headers: _headers, body: jsonEncode(body)),
  );

  Future<Object?> put(String path, Object body) => _send(
    () => _client.put(_uri(path), headers: _headers, body: jsonEncode(body)),
  );

  Future<Object?> delete(String path, {Map<String, String>? query}) =>
      _send(() => _client.delete(_uri(path, query), headers: _headers));

  Future<Object?> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(timeout);
    } on TimeoutException {
      throw ApiException(0, 'network', '连接 ${base.authority} 超时，请检查服务器地址和网络');
    } on SocketException {
      throw ApiException(0, 'network', '无法连接 ${base.authority}，请检查服务器地址和网络');
    } on http.ClientException {
      throw ApiException(0, 'network', '无法连接 ${base.authority}，请检查服务器地址和网络');
    }

    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    Object? json;
    if (text.isNotEmpty) {
      try {
        json = jsonDecode(text);
      } on FormatException {
        json = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;

    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    final error = json is Map ? json['error'] : null;
    if (error is Map) {
      throw ApiException(
        res.statusCode,
        '${error['code'] ?? 'error'}',
        '${error['message'] ?? '服务器返回错误（HTTP ${res.statusCode}）'}',
        deviceIds: [
          for (final id in (error['device_ids'] as List?) ?? const []) '$id',
        ],
      );
    }
    throw ApiException(
      res.statusCode,
      res.statusCode == 404 ? 'not_found' : 'error',
      res.statusCode == 404
          ? '${base.authority} 上没有找到 UniConsole 服务，请检查服务器地址'
          : '服务器返回错误（HTTP ${res.statusCode}）',
    );
  }

  /// 关闭自己创建的连接；外部传入的 client 由调用方关闭。
  void close() {
    if (_ownsClient) _client.close();
  }
}
