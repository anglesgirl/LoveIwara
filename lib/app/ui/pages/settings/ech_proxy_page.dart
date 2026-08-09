import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// ECH 代理管理页
///
/// 通过 MethodChannel 与原生 IwaraApplication 通信（内含 ech-proxy-go）：
/// - 查询/开关代理状态
/// - 连通性测试（任意域名）
/// - Go 内部诊断日志
class EchProxyPage extends StatefulWidget {
  const EchProxyPage({super.key});

  @override
  State<EchProxyPage> createState() => _EchProxyPageState();
}

class _EchProxyPageState extends State<EchProxyPage> {
  static const _channel = MethodChannel('i_iwara/ech_proxy');

  bool _running = false;
  String _duration = '查询中...';
  String _diag = '';
  final TextEditingController _hostCtrl = TextEditingController(text: 'www.iwara.tv');
  String _testResult = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final r = await _channel.invokeMethod('getStatus') as Map?;
      if (mounted) {
        setState(() {
          _running = r?['running'] == true;
          _duration = (r?['status'] as String?) ?? '未知';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _duration = '状态获取失败: $e');
    }
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod('toggle');
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResult = '操作失败: $e';
        });
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runTest() async {
    setState(() {
      _busy = true;
      _testResult = '测试中: ${_hostCtrl.text}...';
    });
    try {
      final r = await _channel.invokeMethod('test', {'host': _hostCtrl.text});
      if (mounted) setState(() => _testResult = (r as String?) ?? '无结果');
    } catch (e) {
      if (mounted) setState(() => _testResult = '测试失败: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _getDiag() async {
    try {
      final r = await _channel.invokeMethod('diagnostics');
      if (mounted) setState(() => _diag = (r as String?) ?? '无诊断');
    } catch (e) {
      if (mounted) setState(() => _diag = '诊断失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🔒 ECH 代理')),
      backgroundColor: const Color(0xFF101428),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 状态卡
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1C2340),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _running ? '🟢 运行中' : '🔴 已停止',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 6),
                Text(
                  '状态: $_duration',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const Text(
                  '代理监听 127.0.0.1:8080（本机可用）',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 开关
          ElevatedButton(
            onPressed: _busy ? null : _toggle,
            style: ElevatedButton.styleFrom(
              backgroundColor: _running ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(_running ? '⏹ 停止代理' : '▶ 启动代理'),
          ),
          const SizedBox(height: 16),

          // 测试
          const Text('🧪 连通性测试', style: TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hostCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: '输入域名，如 www.iwara.tv',
                    hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                    filled: true,
                    fillColor: Color(0xFF1C2340),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _busy ? null : _runTest,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0)),
                child: const Text('测试'),
              ),
            ],
          ),
          if (_testResult.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1322),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _testResult,
                style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ],
          const SizedBox(height: 16),

          // 诊断
          Row(
            children: [
              ElevatedButton(
                onPressed: _getDiag,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00695C)),
                child: const Text('🔬 Go 诊断'),
              ),
              const SizedBox(width: 8),
              const Text('日志自动写入文件', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          if (_diag.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1322),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _diag,
                style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}