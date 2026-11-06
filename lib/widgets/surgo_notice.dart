import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// The app's single presentation for transient feedback. Every snackbar goes
/// through here so confirmations, warnings and failures share one shape,
/// icon treatment and palette instead of falling back to Material defaults.
enum SbNoticeTone { info, success, warning, danger }

extension _NoticeStyle on SbNoticeTone {
  SbTone get tone => switch (this) {
        SbNoticeTone.info => SbTone.info,
        SbNoticeTone.success => SbTone.success,
        SbNoticeTone.warning => SbTone.warning,
        SbNoticeTone.danger => SbTone.danger,
      };

  IconData get icon => switch (this) {
        SbNoticeTone.info => Icons.info_outline_rounded,
        SbNoticeTone.success => Icons.check_circle_outline_rounded,
        SbNoticeTone.warning => Icons.error_outline_rounded,
        SbNoticeTone.danger => Icons.warning_amber_rounded,
      };
}

class SurgoNotice {
  SurgoNotice._();

  static void show(
    BuildContext context,
    String message, {
    SbNoticeTone tone = SbNoticeTone.info,
    String? title,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final style = tone.tone;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.panel2,
          elevation: 10,
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: SbRadius.card,
            side: BorderSide(color: style.border),
          ),
          content: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: style.soft,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(tone.icon, size: 16, color: style.accent),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (title != null) ...[
                        Text(
                          title,
                          style: TextStyle(
                            color: style.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 1),
                      ],
                      Text(
                        message,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }

  /// A styled confirmation alert. Returns true only when the user confirms.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    SbTone tone = SbTone.brand,
    IconData icon = Icons.help_outline_rounded,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.panel2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SbRadius.lg),
          side: const BorderSide(color: AppColors.borderLight),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone.soft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: tone.accent),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: TextButton.styleFrom(foregroundColor: AppColors.muted),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor:
                  destructive ? AppColors.danger : AppColors.primaryLight,
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
