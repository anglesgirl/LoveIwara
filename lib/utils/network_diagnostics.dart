import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:i_iwara/app/models/iwara_site.dart';
import 'package:i_iwara/app/services/http_client_factory.dart';
import 'package:i_iwara/app/services/iwara_site_headers.dart';
import 'package:i_iwara/common/constants.dart';

/// 网络诊断报告构建器。
///
/// 目标：把「登录 / 请求失败」的**真实网络原因**——DioException 类型、底层
/// [SocketException] / [TlsException] 的 errno、Cloudflare 拦截头、响应体片段——
/// 连同 App / 站点 / 代理上下文整理成一段可复制、可分享的纯文本，供用户截图或
/// 粘贴给开发者定位「登不进去 / 网络异常 / 请求超时」这类只在真机上复现的问题。
///
/// ⚠️ 隐私：**绝不包含账号、密码、token**——登录请求体不会被打印；仅在请求
/// 失败（异常路径）时构建，此时响应体是错误页 / 错误 JSON，不含成功态的凭据。
class NetworkDiagnostics {
  const NetworkDiagnostics._();

  /// 响应体片段最大长度（Cloudflare 挑战页 / 错误 JSON 可能很长）。
  static const int _bodySnippetMax = 300;

  /// 构建完整诊断文本。
  ///
  /// [stage] 标注失败环节（如 `login`）；[friendly] 为已归类的用户友好文案，
  /// 便于把「技术原因」与「归类结论」并列展示。
  static String describe(
    Object? error, {
    String? stage,
    String? friendly,
    DateTime? nowOverride,
  }) {
    final b = StringBuffer()
      ..writeln('=== 网络诊断 / Network Diagnostics ===')
      ..writeln('时间 time: ${(nowOverride ?? DateTime.now()).toIso8601String()}')
      ..writeln('版本 version: ${CommonConstants.VERSION}')
      ..writeln('平台 platform: ${_platform()}');
    if (stage != null && stage.isNotEmpty) {
      b.writeln('环节 stage: $stage');
    }
    b
      ..writeln('站点 site: ${_siteLabel()}')
      ..writeln('接口 api: ${CommonConstants.iwaraApiBaseUrl}')
      ..writeln('代理 proxy: ${_proxyLabel()}');
    if (friendly != null && friendly.isNotEmpty) {
      b.writeln('归类 summary: $friendly');
    }
    b.writeln('--- 底层错误 / raw error ---');
    _describeError(error, b);
    return b.toString().trimRight();
  }

  static void _describeError(Object? error, StringBuffer b) {
    if (error == null) {
      b.writeln('(无异常对象 / no exception object)');
      return;
    }

    if (error is DioException) {
      final req = error.requestOptions;
      b
        ..writeln('类型 dioType: ${error.type.name}')
        ..writeln('请求 request: ${req.method} ${req.uri}');

      final status = error.response?.statusCode;
      if (status != null) {
        final reason = error.response?.statusMessage ?? '';
        b.writeln('状态码 status: $status ${reason.trim()}'.trimRight());
      }
      if (error.message != null && error.message!.isNotEmpty) {
        b.writeln('消息 message: ${error.message}');
      }

      final cf = _cloudflareInfo(error.response);
      if (cf != null) {
        b.writeln('Cloudflare: $cf');
      }

      final cause = error.error;
      if (cause != null) {
        b.writeln('底层类型 cause: ${cause.runtimeType}');
        _describeUnderlying(cause, b);
      }

      final snippet = _responseSnippet(error.response?.data);
      if (snippet != null) {
        b.writeln('响应片段 body: $snippet');
      }
      return;
    }

    // 非 Dio 异常（含 TokenManager 透传的错误消息字符串等）。
    b
      ..writeln('类型 type: ${error.runtimeType}')
      ..writeln('内容 detail: $error');
  }

  /// 解包底层错误——真正能说明「为什么连不上」的信息（errno/主机/端口）多在这里。
  static void _describeUnderlying(Object cause, StringBuffer b) {
    if (cause is SocketException) {
      if (cause.message.isNotEmpty) {
        b.writeln('  socket: ${cause.message}');
      }
      final os = cause.osError;
      if (os != null) {
        b.writeln('  errno: ${os.errorCode} (${os.message})');
      }
      final addr = cause.address;
      if (addr != null) {
        b.writeln('  address: ${addr.host} → ${addr.address}');
      }
      if (cause.port != null) {
        b.writeln('  port: ${cause.port}');
      }
      return;
    }

    if (cause is HandshakeException) {
      b.writeln('  handshake: ${cause.message}');
      final os = cause.osError;
      if (os != null) {
        b.writeln('  errno: ${os.errorCode} (${os.message})');
      }
      return;
    }

    if (cause is TlsException) {
      b.writeln('  tls: ${cause.message}');
      final os = cause.osError;
      if (os != null) {
        b.writeln('  errno: ${os.errorCode} (${os.message})');
      }
      return;
    }

    if (cause is HttpException) {
      b.writeln('  http: ${cause.message}');
      return;
    }

    b.writeln('  detail: $cause');
  }

  /// 提取 Cloudflare 相关响应头/标记——判断「是被 CF 挡了还是真连不上」的关键。
  static String? _cloudflareInfo(Response<dynamic>? response) {
    if (response == null) return null;
    final parts = <String>[];
    final mitigated = response.headers.value('cf-mitigated');
    if (mitigated != null) parts.add('mitigated=$mitigated');
    final ray = response.headers.value('cf-ray');
    if (ray != null) parts.add('ray=$ray');
    final server = response.headers.value('server');
    if (server != null && server.toLowerCase().contains('cloudflare')) {
      parts.add('server=$server');
    }
    if (response.extra['cloudflare'] == true) parts.add('challenge=true');
    return parts.isEmpty ? null : parts.join(' ');
  }

  static String? _responseSnippet(dynamic data) {
    if (data == null) return null;
    var s = (data is String ? data : data.toString())
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.isEmpty) return null;
    if (s.length > _bodySnippetMax) {
      s = '${s.substring(0, _bodySnippetMax)}…(${s.length})';
    }
    return s;
  }

  static String _platform() {
    if (kIsWeb) return 'web';
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  static String _siteLabel() {
    try {
      final site = currentIwaraSiteOrMain();
      return '${site.name} (${site.baseUrl})';
    } catch (_) {
      return 'unknown';
    }
  }

  static String _proxyLabel() {
    try {
      final factory = HttpClientFactory.instance;
      return factory.hasProxy ? (factory.proxyDescription ?? 'on') : 'off (直连)';
    } catch (_) {
      return 'unknown';
    }
  }
}
