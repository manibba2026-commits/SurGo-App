import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import 'common.dart';

/// Account-level verification summary row for the profile tabs. [onTap]
/// opens the verification centre.
class VerificationStatusRow extends StatelessWidget {
  final VoidCallback? onTap;

  const VerificationStatusRow({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SbCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        onTap: onTap,
        child: Row(
          children: [
            const Icon(Icons.verified_user_outlined,
                size: 18, color: AppColors.primaryLight),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Verification & documents',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
            SbTag(state.verificationSummaryLabel, secondary: true),
          ],
        ),
      ),
    );
  }
}
