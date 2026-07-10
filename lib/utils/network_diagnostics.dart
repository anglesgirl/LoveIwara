import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart' hide Response;
import 'package:i_iwara/app/models/iwara_site.dart';
import 'package:i_iwara/app/services/config_service.dart';
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
      ..writeln('代理 proxy: ${_proxyLabel()}')
      ..writeln('代理配置 proxyConfig: ${_proxyConfigLabel()}');
    if (friendly != null && friendly.isNotEmpty) {
      b.writeln('归类 summary: $friendly');
    }
    b.writeln('--- 底层错误 / raw error ---');
    _describeError(error, b);
    return b.toString().trimRight();
  }

  /// 在 [describe] 基础上追加一次**主动 DNS 解析探测**（[probeDns]）。
  ///
  /// 这是区分两类 `errno 111 / connection refused` 报障的**决定性**一手证据：
  /// - 「App 直连被拒 / 未继承系统代理」——健康解析应命中 Cloudflare 公布网段；
  /// - 「DNS 被污染到死 IP」——解析会落到私有 / 保留 / 非 Cloudflare 地址，
  ///   而浏览器多半是靠自带 DoH（安全 DNS）+ ECH 才打得开。
  ///
  /// 异步、带超时、绝不抛出；调用方在 await 后请自行重新校验 `mounted`。
  static Future<String> describeAsync(
    Object? error, {
    String? stage,
    String? friendly,
    DateTime? nowOverride,
    Duration dnsTimeout = const Duration(seconds: 4),
  }) async {
    final base = describe(
      error,
      stage: stage,
      friendly: friendly,
      nowOverride: nowOverride,
    );
    final probe = await probeDns(timeout: dnsTimeout);
    return '$base\n$probe'.trimRight();
  }

  /// 用系统解析器主动解析 API 域名，列出返回的 IP、地址族，并与 Cloudflare
  /// 公布网段比对，判断是否疑似 DNS 污染。绝不抛出。
  static Future<String> probeDns({
    Duration timeout = const Duration(seconds: 4),
    String? host,
  }) async {
    final target = host ?? _apiHost();
    final b = StringBuffer()
      ..writeln('--- DNS 解析探测 / DNS probe ---')
      ..writeln('主机 host: $target');
    final sw = Stopwatch()..start();
    try {
      final addrs = await InternetAddress.lookup(target).timeout(timeout);
      sw.stop();
      if (addrs.isEmpty) {
        b
          ..writeln('解析 lookup (${sw.elapsedMilliseconds}ms): (空 / empty)')
          ..writeln('判定 verdict: ⚠ 解析返回空结果，疑似 DNS 污染或网络异常');
        return b.toString().trimRight();
      }
      var cfHit = false;
      var suspicious = false;
      var fakeIp = false;
      final parts = <String>[];
      for (final a in addrs) {
        final family = a.type == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';
        final klass = _classifyIp(a);
        if (klass == _IpClass.cloudflare) cfHit = true;
        if (klass == _IpClass.suspicious) suspicious = true;
        if (klass == _IpClass.fakeIp) fakeIp = true;
        parts.add('${a.address} [$family ${_ipClassLabel(klass)}]');
      }
      b
        ..writeln('解析 lookup (${sw.elapsedMilliseconds}ms): ${parts.join(', ')}')
        ..writeln(
          '判定 verdict: '
          '${_dnsVerdict(cfHit: cfHit, suspicious: suspicious, fakeIp: fakeIp)}',
        );
    } catch (e) {
      sw.stop();
      b
        ..writeln('解析 lookup (${sw.elapsedMilliseconds}ms): 失败 / failed')
        ..writeln('错误 error: ${e.runtimeType} $e')
        ..writeln('判定 verdict: ⚠ 解析失败/超时——DNS 被污染/被墙或无网络时的典型表现');
    }
    return b.toString().trimRight();
  }

  static String _apiHost() {
    try {
      final host = Uri.parse(CommonConstants.iwaraApiBaseUrl).host;
      return host.isEmpty ? 'apiq.iwara.tv' : host;
    } catch (_) {
      return 'apiq.iwara.tv';
    }
  }

  /// Cloudflare 官方公布网段（IPv4: /ips-v4，IPv6: /ips-v6）。
  /// apiq.iwara.tv 由 Cloudflare 托管，健康解析应命中其一。
  static const List<String> _cloudflareCidrs = [
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/13',
    '104.24.0.0/14',
    '172.64.0.0/13',
    '131.0.72.0/22',
    '2400:cb00::/32',
    '2606:4700::/32',
    '2803:f800::/32',
    '2405:b500::/32',
    '2405:8100::/32',
    '2a06:98c0::/29',
    '2c0f:f248::/32',
  ];

  static _IpClass _classifyIp(InternetAddress a) {
    if (a.isLoopback) return _IpClass.suspicious;
    final raw = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      if (raw.length != 4) return _IpClass.unknown;
      final b0 = raw[0];
      final b1 = raw[1];
      // 私有 / 保留：0/8、10/8、100.64/10(CGNAT)、127/8、169.254/16、
      // 172.16/12、192.168/16
      if (b0 == 0 || b0 == 10 || b0 == 127) return _IpClass.suspicious;
      if (b0 == 169 && b1 == 254) return _IpClass.suspicious;
      if (b0 == 172 && b1 >= 16 && b1 <= 31) return _IpClass.suspicious;
      if (b0 == 192 && b1 == 168) return _IpClass.suspicious;
      if (b0 == 100 && b1 >= 64 && b1 <= 127) return _IpClass.suspicious;
      // 198.18.0.0/15（RFC 2544 基准测试保留段）：Clash/sing-box 等 TUN 代理
      // fake-ip 模式的默认网段——命中即说明设备正走系统级代理，不是污染。
      if (b0 == 198 && (b1 == 18 || b1 == 19)) return _IpClass.fakeIp;
    } else if (a.type == InternetAddressType.IPv6 && raw.length == 16) {
      final allZero = raw.every((x) => x == 0);
      if (allZero) return _IpClass.suspicious;
      if ((raw[0] & 0xfe) == 0xfc) return _IpClass.suspicious; // fc00::/7 唯一本地
      if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) {
        return _IpClass.suspicious; // fe80::/10 链路本地
      }
    }
    return _isCloudflare(a) ? _IpClass.cloudflare : _IpClass.other;
  }

  static bool _isCloudflare(InternetAddress a) {
    final addr = a.rawAddress;
    for (final cidr in _cloudflareCidrs) {
      final slash = cidr.indexOf('/');
      if (slash < 0) continue;
      final net = InternetAddress.tryParse(cidr.substring(0, slash));
      final prefix = int.tryParse(cidr.substring(slash + 1));
      if (net == null || prefix == null) continue;
      final netRaw = net.rawAddress;
      if (netRaw.length != addr.length) continue; // 地址族不同，跳过
      if (_matchPrefix(addr, netRaw, prefix)) return true;
    }
    return false;
  }

  /// 比较两个原始地址的前 [prefixBits] 位是否一致（IPv4/IPv6 通用）。
  static bool _matchPrefix(Uint8List a, Uint8List net, int prefixBits) {
    var bits = prefixBits;
    var i = 0;
    while (bits >= 8) {
      if (i >= a.length || a[i] != net[i]) return false;
      i++;
      bits -= 8;
    }
    if (bits > 0 && i < a.length) {
      final mask = (0xff << (8 - bits)) & 0xff;
      if ((a[i] & mask) != (net[i] & mask)) return false;
    }
    return true;
  }

  static String _ipClassLabel(_IpClass c) {
    switch (c) {
      case _IpClass.cloudflare:
        return '~Cloudflare';
      case _IpClass.suspicious:
        return '⚠私有/保留';
      case _IpClass.fakeIp:
        return '⚑fake-ip(TUN代理)';
      case _IpClass.other:
        return '?非CF';
      case _IpClass.unknown:
        return '?';
    }
  }

  static String _dnsVerdict({
    required bool cfHit,
    required bool suspicious,
    required bool fakeIp,
  }) {
    if (fakeIp) {
      return '⚑ 解析到 fake-ip 段（198.18.0.0/15）——设备正在走 TUN/VPN 代理'
          '（Clash/sing-box 类），DNS 由代理接管，这不是污染；'
          '连接失败时应检查代理节点/分流规则';
    }
    if (suspicious) {
      return '⚠ 解析到私有/保留/回环地址，高度疑似 DNS 污染'
          '（浏览器多半靠自带 DoH 才能打开）';
    }
    if (cfHit) {
      return '命中 Cloudflare 段（DNS 解析正常）——'
          '问题更可能是直连被拒/未走代理，而非污染';
    }
    return '⚠ 未命中 Cloudflare 段，可能是 DNS 污染或 CDN 变更，请核对返回 IP';
  }

  /// 主动**多 host 连通性体检**：对 App 依赖的关键外部 host（Iwara API +
  /// GitHub 更新源）分别做 DNS 解析 + 真实 HTTPS 连接尝试，汇总成可复制文本。
  ///
  /// 供诊断页「运行网络诊断」手动触发——已登录、内容全刷不出来的用户不必等某个
  /// 失败请求即可自查。两个**互不相关**的基础设施一起挂本身就是强信号：
  /// - 各 host 都解析到私有/保留 IP 或解析失败 → DNS 污染（系统性）；
  /// - 各 host 都解析到正常公网 IP 但连接被拒/超时 → 直连被墙（需代理/TUN）；
  /// - 浏览器能开而此处全失败 → App 未走浏览器所用的代理通道。
  ///
  /// 连接尝试复用共享 [HttpClientFactory] 客户端，因此**如实反映 App 实际出口**
  /// （已配的 App 代理会生效）。绝不抛出。
  static Future<String> runConnectivityReport({
    Duration perHostTimeout = const Duration(seconds: 6),
  }) async {
    final targets = <_ProbeTarget>[
      _ProbeTarget(
        'Iwara API',
        CommonConstants.iwaraApiBaseUrl,
        expectCloudflare: true,
      ),
      const _ProbeTarget(
        'GitHub 更新日志',
        'https://raw.githubusercontent.com',
        expectCloudflare: false,
      ),
      const _ProbeTarget(
        'GitHub 站点',
        'https://github.com',
        expectCloudflare: false,
      ),
    ];

    final b = StringBuffer()
      ..writeln('=== 网络连通性体检 / Connectivity check ===')
      ..writeln('时间 time: ${DateTime.now().toIso8601String()}')
      ..writeln('版本 version: ${CommonConstants.VERSION}')
      ..writeln('平台 platform: ${_platform()}')
      ..writeln('站点 site: ${_siteLabel()}')
      ..writeln('代理 proxy: ${_proxyLabel()}')
      ..writeln('代理配置 proxyConfig: ${_proxyConfigLabel()}');

    for (final target in targets) {
      b.writeln('');
      await _probeTarget(target, b, perHostTimeout);
    }

    b
      ..writeln('')
      ..writeln('--- 判读提示 / how to read ---')
      ..writeln(
        '各 host 都解析到 198.18.x fake-ip → 设备正开着 TUN/VPN 代理'
        '（即使上方 App 内代理显示 off），个别 host 失败=该 host 的代理节点/分流规则问题；',
      )
      ..writeln(
        '各 host 都解析到私有/保留 IP 或解析失败 → DNS 污染（系统性，需 App 内 DoH 或 TUN）；',
      )
      ..writeln('各 host 都解析到正常公网 IP 但连接被拒/超时 → 直连被墙（需走代理或 TUN 模式）；')
      ..writeln('浏览器能开而此处全失败 → App 未走浏览器所用的代理通道。');
    return b.toString().trimRight();
  }

  static Future<void> _probeTarget(
    _ProbeTarget target,
    StringBuffer b,
    Duration timeout,
  ) async {
    final uri = Uri.parse(target.url);
    final host = uri.host;
    b.writeln('--- ${target.label} ($host) ---');

    // 1) DNS 解析（系统解析器 —— App 看到的就是它）
    final dnsSw = Stopwatch()..start();
    try {
      final addrs = await InternetAddress.lookup(host).timeout(timeout);
      dnsSw.stop();
      if (addrs.isEmpty) {
        b
          ..writeln('DNS (${dnsSw.elapsedMilliseconds}ms): (空 / empty)')
          ..writeln('  判定 verdict: ⚠ 解析返回空结果，疑似 DNS 污染或网络异常');
      } else {
        var cfHit = false;
        var suspicious = false;
        var fakeIp = false;
        final parts = <String>[];
        for (final a in addrs) {
          final family = a.type == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';
          final klass = _classifyIp(a);
          if (klass == _IpClass.cloudflare) cfHit = true;
          if (klass == _IpClass.suspicious) suspicious = true;
          if (klass == _IpClass.fakeIp) fakeIp = true;
          parts.add('${a.address} [$family ${_ipClassLabel(klass)}]');
        }
        b
          ..writeln('DNS (${dnsSw.elapsedMilliseconds}ms): ${parts.join(', ')}')
          ..writeln(
            '  判定 verdict: ${_hostDnsVerdict(cfHit: cfHit, suspicious: suspicious, fakeIp: fakeIp, expectCloudflare: target.expectCloudflare)}',
          );
      }
    } catch (e) {
      dnsSw.stop();
      b
        ..writeln('DNS (${dnsSw.elapsedMilliseconds}ms): 失败 / failed — ${e.runtimeType}')
        ..writeln('  判定 verdict: ⚠ 解析失败/超时——DNS 被污染/被墙或无网络时的典型表现');
    }

    // 2) 真实连接（走 App 实际出口：共享 HttpClient，含已配代理）
    final connSw = Stopwatch()..start();
    try {
      final client = HttpClientFactory.instance.createHttpClient();
      final request = await client.openUrl('HEAD', uri).timeout(timeout);
      request.followRedirects = true;
      final response = await request.close().timeout(timeout);
      connSw.stop();
      await response.drain<void>();
      b.writeln('连接 connect (${connSw.elapsedMilliseconds}ms): HTTP ${response.statusCode} ✓ 可达');
    } catch (e) {
      connSw.stop();
      b.writeln('连接 connect (${connSw.elapsedMilliseconds}ms): ✗ ${_connectErrorLabel(e)}');
    }
  }

  static String _hostDnsVerdict({
    required bool cfHit,
    required bool suspicious,
    required bool fakeIp,
    required bool expectCloudflare,
  }) {
    if (fakeIp) {
      return '⚑ fake-ip 段（198.18.0.0/15）——设备正走 TUN/VPN 代理，'
          'DNS 由代理接管，非污染；连接结果反映代理出口质量';
    }
    if (suspicious) {
      return '⚠ 私有/保留/回环地址，高度疑似 DNS 污染';
    }
    if (expectCloudflare) {
      return cfHit
          ? '命中 Cloudflare 段（解析正常）'
          : '⚠ 未命中 Cloudflare 段，疑似污染或 CDN 变更';
    }
    return '公网地址（非污染典型值，看连接结果判断）';
  }

  static String _connectErrorLabel(Object e) {
    if (e is TimeoutException) return '超时 timeout（丢包/被墙黑洞的典型表现）';
    if (e is SocketException) {
      final os = e.osError;
      final errno = os != null ? ' errno=${os.errorCode}(${os.message})' : '';
      return '连接失败: ${e.message}$errno';
    }
    if (e is HandshakeException) return 'TLS 握手失败: ${e.message}';
    if (e is TlsException) return 'TLS: ${e.message}';
    if (e is HttpException) return 'HTTP: ${e.message}';
    return '${e.runtimeType}: $e';
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

  /// 用户在 App 内的**代理配置意图**（区别于 [_proxyLabel] 反映的已生效代理）：
  /// 捕获「开了 USE_PROXY 但 PROXY_URL 非法被清空」这类边界，且移动端从不读
  /// 系统代理——USE_PROXY=false 即意味着 App 走直连。
  static String _proxyConfigLabel() {
    try {
      if (!Get.isRegistered<ConfigService>()) return 'unavailable';
      final config = Get.find<ConfigService>();
      final use = config.settings[ConfigKey.USE_PROXY]?.value;
      final url = config.settings[ConfigKey.PROXY_URL]?.value;
      final shownUrl = (url is String && url.isNotEmpty) ? url : '(空)';
      return 'USE_PROXY=$use PROXY_URL=$shownUrl';
    } catch (_) {
      return 'unavailable';
    }
  }
}

/// [NetworkDiagnostics.runConnectivityReport] 的探测目标。
class _ProbeTarget {
  const _ProbeTarget(
    this.label,
    this.url, {
    required this.expectCloudflare,
  });

  /// 展示名（如 `Iwara API`）。
  final String label;

  /// 目标 URL（用于取 host 做 DNS + 发起连接）。
  final String url;

  /// 该 host 是否应命中 Cloudflare 段（Iwara=true；GitHub 走 Fastly=false）。
  final bool expectCloudflare;
}

/// [_classifyIp] 的判定结果：解析到的地址落在哪一类。
enum _IpClass {
  /// 命中 Cloudflare 公布网段——健康解析。
  cloudflare,

  /// 私有 / 保留 / 回环 / 链路本地等——高度疑似 DNS 污染。
  suspicious,

  /// 198.18.0.0/15 fake-ip 段——设备正走 TUN/VPN 代理，DNS 由代理接管。
  fakeIp,

  /// 公网但不在 Cloudflare 段——存疑（污染或 CDN 变更）。
  other,

  /// 无法判定（地址字节异常）。
  unknown,
}
