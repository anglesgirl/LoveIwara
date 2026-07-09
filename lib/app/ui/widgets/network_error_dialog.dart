import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:oktoast/oktoast.dart';
import 'package:share_plus/share_plus.dart';

import 'package:i_iwara/app/ui/widgets/md_toast_widget.dart';
import 'package:i_iwara/i18n/strings.g.dart' as slang;

/// 网络失败诊断弹窗。
///
/// 展示一段由 [NetworkDiagnostics] 生成的**真实网络原因**纯文本（可选中、可复制、
/// 可分享），让用户一键复制发给开发者定位「登不进去 / 网络异常 / 请求超时」问题。
class NetworkErrorDialog extends StatelessWidget {
  const NetworkErrorDialog({
    super.key,
    required this.report,
    this.friendly,
  });

  /// 完整诊断文本（技术细节）。
  final String report;

  /// 已归类的用户友好摘要（可空）。
  final String? friendly;

  static Future<void> show(
    BuildContext context, {
    required String report,
    String? friendly,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => NetworkErrorDialog(report: report, friendly: friendly),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: report));
    showToastWidget(
      MDToastWidget(
        message: slang.t.common.copiedToClipboard,
        type: MDToastType.success,
      ),
    );
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: report,
          subject: slang.t.errors.network.diagnostics.title,
        ),
      );
    } catch (_) {
      // 分享通道不可用时退回复制。
      await _copy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = slang.t;
    // share_plus 的纯文本分享在移动端可靠；桌面端仅提供复制。
    final canShare = !GetPlatform.isDesktop;

    return AlertDialog(
      icon: Icon(
        Icons.wifi_tethering_error_rounded,
        color: theme.colorScheme.error,
      ),
      title: Text(t.errors.network.diagnostics.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (friendly != null && friendly!.isNotEmpty) ...[
                Text(
                  friendly!,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                t.errors.network.diagnostics.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t.errors.network.diagnostics.detailsLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      report,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.common.close),
        ),
        if (canShare)
          TextButton.icon(
            onPressed: _share,
            icon: const Icon(Icons.ios_share, size: 18),
            label: Text(t.common.share),
          ),
        FilledButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(t.common.copy),
        ),
      ],
    );
  }
}
