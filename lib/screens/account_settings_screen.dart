import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../auth/demo_auth.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';

class AccountSettingsScreen extends StatelessWidget {
  final bool isRider;
  const AccountSettingsScreen({super.key, this.isRider = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Account Settings')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final settings = isRider ? state.earnerSettings : state.passengerSettings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              const Text('Notifications', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.muted)),
              const SizedBox(height: 8),
              _switchTile(
                'Push Notifications',
                'Ride, rental, and safety alerts',
                settings.pushNotifications,
                (v) => isRider
                    ? state.updateRiderSettings((s) => s.pushNotifications = v)
                    : state.updatePassengerSettings((s) => s.pushNotifications = v),
              ),
              if (!isRider) ...[
                const SizedBox(height: 8),
                _switchTile(
                  'SMS Alerts',
                  'For low-signal barangay areas',
                  settings.smsAlerts,
                  (v) => state.updatePassengerSettings((s) => s.smsAlerts = v),
                ),
              ],
              if (isRider) ...[
                const SizedBox(height: 8),
                _switchTile(
                  'Auto-accept Nearby Requests',
                  'Automatically accept rides under 3 km',
                  settings.autoAcceptNearby,
                  (v) => state.updateRiderSettings((s) => s.autoAcceptNearby = v),
                ),
              ],
              const SizedBox(height: 8),
              _switchTile(
                'Low-Data Mode',
                'Reduce map and image data usage',
                settings.lowDataMode,
                (v) => isRider
                    ? state.updateRiderSettings((s) => s.lowDataMode = v)
                    : state.updatePassengerSettings((s) => s.lowDataMode = v),
              ),
              const SizedBox(height: 20),
              const Text('Preferences', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.muted)),
              const SizedBox(height: 8),
              SbCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                onTap: () => SurgoNotice.show(
                  context,
                  'Only English is available in this simulation',
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Language', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Row(
                      children: [
                        Text(settings.language, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                        const SizedBox(width: 6),
                        const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Sign-in & security',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              _linkedPhoneTile(context, state),
              const SizedBox(height: 8),
              _linkedGoogleTile(context, state),
              if (state.demoAuthEnabled) ...[
                const SizedBox(height: 8),
                _pinTile(context),
              ],
              const SizedBox(height: 24),
              SbOutlineButton(
                label: 'Log Out',
                icon: Icons.logout,
                onPressed: () => _confirmLogout(context),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _linkedPhoneTile(BuildContext context, AppState state) {
    final linked = state.identity?.hasPhoneIdentity ??
        (state.currentAccount?.phone.isNotEmpty ?? false);
    final phone = state.identity?.phone ?? state.currentAccount?.phone ?? '';
    return SbTintedCard(
      tone: linked ? SbTone.success : SbTone.brand,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          SbToneIcon(
            tone: linked ? SbTone.success : SbTone.brand,
            icon: Icons.phone_iphone,
            size: 34,
            iconSize: 17,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Phone number',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  linked ? phone : 'Not linked yet',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (linked)
            const Icon(Icons.check_circle, size: 17, color: AppColors.success)
          else
            TextButton(
              onPressed: () => _linkPhone(context),
              child: const Text('Add'),
            ),
        ],
      ),
    );
  }

  Widget _linkedGoogleTile(BuildContext context, AppState state) {
    final linked = state.identity?.hasGoogleIdentity ?? false;
    return SbTintedCard(
      tone: linked ? SbTone.success : SbTone.brand,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          SbToneIcon(
            tone: linked ? SbTone.success : SbTone.brand,
            icon: Icons.g_mobiledata,
            size: 34,
            iconSize: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Google',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  linked ? 'Linked to this account' : 'Not linked yet',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (linked)
            const Icon(Icons.check_circle, size: 17, color: AppColors.success)
          else
            TextButton(
              onPressed: () => _linkGoogle(context),
              child: const Text('Link'),
            ),
        ],
      ),
    );
  }

  Future<void> _linkPhone(BuildContext context) async {
    final controller = TextEditingController();
    final phone = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            backgroundColor: AppColors.panel,
            title: const Text('Add a phone number'),
            content: TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '+63 9XX XXX XXXX',
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final normalized = normalizePhoneNumber(controller.text);
                  if (normalized == null) {
                    setDialogState(() =>
                        error = 'Enter a valid number with the country code.');
                    return;
                  }
                  Navigator.pop(dialogContext, normalized);
                },
                child: const Text('Send code'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (phone == null || !context.mounted) return;

    final state = AppState.instance;
    final failure = await state.requestPhoneLink(phone);
    if (!context.mounted) return;
    if (failure != null) {
      SurgoNotice.show(context, failure.message, tone: SbNoticeTone.danger);
      return;
    }

    final linked = await Navigator.pushNamed(
      context,
      '/otp',
      arguments: {'phone': phone, 'mode': 'linkPhone'},
    );
    if (linked == true && context.mounted) {
      SurgoNotice.show(
        context,
        'Phone number linked.',
        tone: SbNoticeTone.success,
      );
    }
  }

  Future<void> _linkGoogle(BuildContext context) async {
    final state = AppState.instance;
    final failure = await state.linkGoogleIdentity();
    if (!context.mounted) return;
    if (failure != null) {
      SurgoNotice.show(context, failure.message, tone: SbNoticeTone.danger);
      return;
    }
    final linkedNow = state.identity?.hasGoogleIdentity ?? false;
    SurgoNotice.show(
      context,
      linkedNow
          ? 'Google linked to this account.'
          : 'Finish linking Google in the browser window.',
      tone: linkedNow ? SbNoticeTone.success : SbNoticeTone.info,
    );
  }

  Widget _pinTile(BuildContext context) {
    return SbCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: () => _changePin(context),
      child: Row(
        children: [
          const SbToneIcon(
            tone: SbTone.brand,
            icon: Icons.lock_outline,
            size: 34,
            iconSize: 17,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'App PIN',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 2),
                Text(
                  'Required when SurGo reopens',
                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const Text(
            'Change',
            style: TextStyle(
              color: AppColors.primaryLight,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
        ],
      ),
    );
  }

  Future<void> _changePin(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;

    Future<void> save(StateSetter setDialogState, BuildContext dialogContext) async {
      final currentPin = current.text.trim();
      final nextPin = next.text.trim();
      if (!isDemoPin(currentPin)) {
        setDialogState(() => error = 'Enter your current 6-digit PIN.');
        return;
      }
      if (!isDemoPin(nextPin)) {
        setDialogState(() => error = 'The new PIN must be 6 digits.');
        return;
      }
      if (nextPin != confirm.text.trim()) {
        setDialogState(() => error = 'The new PINs do not match.');
        return;
      }

      final result = await AppState.instance.changePin(
        currentPin: currentPin,
        newPin: nextPin,
      );
      if (!dialogContext.mounted) return;
      if (result == PinChangeResult.success) {
        Navigator.pop(dialogContext, true);
        return;
      }
      setDialogState(() => error = switch (result) {
            PinChangeResult.incorrectCurrent => 'That is not the current PIN.',
            PinChangeResult.sameAsCurrent =>
              'Choose a PIN different from the current one.',
            _ => 'Enter a 6-digit PIN.',
          });
    }

    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.panel,
              title: const Text('Change app PIN'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: current,
                      autofocus: true,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: DemoAuthConfig.pinLength,
                      decoration: const InputDecoration(
                        labelText: 'Current PIN',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: next,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: DemoAuthConfig.pinLength,
                      decoration: const InputDecoration(
                        labelText: 'New PIN',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: confirm,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: DemoAuthConfig.pinLength,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new PIN',
                        counterText: '',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error!,
                          style: const TextStyle(
                            color: AppColors.danger,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => save(setDialogState, dialogContext),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    current.dispose();
    next.dispose();
    confirm.dispose();
    if (changed == true && context.mounted) {
      SurgoNotice.show(
        context,
        'App PIN updated.',
        tone: SbNoticeTone.success,
      );
    }
  }

  Widget _switchTile(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SbCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          Switch(
            value: value,
            activeColor: Colors.white,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.panel2,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await SurgoNotice.confirm(
      context,
      title: 'Log out?',
      message: "You'll be returned to the login screen.",
      confirmLabel: 'Log Out',
      icon: Icons.logout_rounded,
      tone: SbTone.danger,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await AppState.instance.logout();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }
}
