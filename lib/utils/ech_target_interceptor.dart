import 'package:dio/dio.dart' as dio;

/// ECH 传输拦截器
///
/// 把 https://host/path 改写为 http://127.0.0.1:8080/path + 头 X-Ech-Target: host，
/// 流量走内置 ech-proxy-go：DoH 干净解析 + ECH 直连，绕开 DNS 污染与被墙。
class EchTargetInterceptor extends dio.Interceptor {
  /// 本地 ECH 代理地址（内置 ech-proxy-go 监听）
  static const String proxyHost = '127.0.0.1';
  static const int proxyPort = 8080;

  /// 只启用的域名前缀（后续可按需扩展）
  static const List<String> _defaultHosts = [
    'iwara.tv',
    'iwara.ai',
    'apiv2.hitomi.la',
  ];

  final List<String> _hosts;

  EchTargetInterceptor({List<String>? hosts}) : _hosts = hosts ?? _defaultHosts;

  bool _shouldProxy(String host) {
    final h = host.toLowerCase();
    return _hosts.any((s) => h == s || h.endsWith('.$s'));
  }

  @override
  void onRequest(
    dio.RequestOptions options,
    dio.RequestInterceptorHandler handler,
  ) {
    final uri = options.uri;
    if (uri.scheme == 'https' && _shouldProxy(uri.host)) {
      final host = uri.host;
      // 记录原始目标
      options.headers['X-Ech-Target'] = host;
      // 改写为本地代理（http + X-Ech-Target 头）
      options.baseUrl = 'http://$proxyHost:$proxyPort';
      options.path = uri.path.isEmpty ? '/' : uri.path;
      if (uri.hasQuery) {
        options.path = '${options.path}?${uri.query}';
      }
      options.followRedirects = false;
    }
    handler.next(options);
  }
}