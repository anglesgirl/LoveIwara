import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 干净 DoH 解析器
///
/// 用 Cloudflare Gateway DoH 解析域名，绕开运营商 DNS 污染。
/// 使用 JSON 格式（dns-json），与 ech-proxy-go 一致。
class DoHResolver {
  static const String _tag = 'DoHResolver';

  /// 多端点，失败自动切换
  static const List<String> _endpoints = [
    'https://pieqllv9i7.cloudflare-gateway.com/dns-query',
    'https://al62jgpda0.cloudflare-gateway.com/dns-query',
    'https://2w59vnepne.cloudflare-gateway.com/dns-query',
    'https://m2b4x7vw98.cloudflare-gateway.com/dns-query',
    'https://xzam891f5d.cloudflare-gateway.com/dns-query',
    'https://dz1598pphb.cloudflare-gateway.com/dns-query',
    'https://e6i0vltnvu.cloudflare-gateway.com/dns-query',
  ];

  /// 解析域名，返回第一个 A 记录 IP；失败返回 null
  static Future<String?> resolve(String host) async {
    // 已是 IP 直接返回
    if (InternetAddress.tryParse(host) != null) return host;

    for (final base in _endpoints) {
      try {
        final uri = Uri.parse('$base?name=$host&type=A');
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..idleTimeout = const Duration(seconds: 10);
        try {
          final req = await client.getUrl(uri);
          req.headers.set('Accept', 'application/dns-json');
          final resp = await req.close();
          if (resp.statusCode != 200) continue;
          final body = await resp.transform(utf8.decoder).join();
          final json = jsonDecode(body) as Map<String, dynamic>;
          final answers = json['Answer'] as List? ?? [];
          for (final a in answers) {
            final data = a['data'] as String? ?? '';
            // A 记录（type=1）且是合法 IPv4
            if (a['type'] == 1 && InternetAddress.tryParse(data) != null) {
              return data;
            }
          }
        } finally {
          client.close(force: true);
        }
      } catch (e) {
        debugPrint('$_tag $base 解析 $host 失败: $e');
      }
    }
    return null;
  }
}
