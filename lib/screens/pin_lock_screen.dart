import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/demo_auth.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';

/// The device PIN screen. It carries the whole PIN lifecycle for both the
/// offline demo and a hosted Supabase session:
///
/// * a new account creates a 6-digit PIN and confirms it,
/// * a returning account unlocks with its own PIN,
/// * the resumed session stays locked on relaunch,
/// * repeated failures lock the keypad for a short cooling-off period.
///
/// A PIN is stored per account (see `DemoPinStore`), so switching identities
/// can never unlock the new account with the old account's PIN.
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

enum _PinMode { create, confirm, unlock }

class _PinLockScreenState extends State<PinLockScreen> {
  static const int _length = DemoAuthConfig.pinLength;
  static const int _maxAttempts = 5;
  static const int _lockSeconds = 30;

  AppState get state => AppState.instance;

  _PinMode _mode = _PinMode.unlock;
  String _pin = '';
  String? _firstPin;
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  String? _notice;
  int _failedAttempts = 0;
  int _lockedFor = 0;
  Timer? _lockTimer;

  bool get _locked => _lockedFor > 0;
  bool get _enabled => !_submitting && !_locked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || state.isSignedIn) return;
      Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
    });
    _prepare();
  }

  Future<void> _prepare() async {
    final configured = await state.pinConfiguredForCurrentAccount();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _mode = configured ? _PinMode.unlock : _PinMode.create;
    });
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    super.dispose();
  }

  void _onDigit(String digit) {
    if (!_enabled || _pin.length >= _length) return;
    setState(() {
      _pin += digit;
      _error = null;
      _notice = null;
    });
    if (_pin.length == _length) {
      // Let the last dot paint before deciding on the completed PIN.
      Future.delayed(const Duration(milliseconds: 150), _submit);
    }
  }

  void _onBackspace() {
    if (!_enabled || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (!mounted || _submitting || _locked || _pin.length != _length) return;

    switch (_mode) {
      case _PinMode.create:
        setState(() {
          _firstPin = _pin;
          _pin = '';
          _mode = _PinMode.confirm;
        });
        return;
      case _PinMode.confirm:
        await _confirmPin();
        return;
      case _PinMode.unlock:
        await _unlock();
        return;
    }
  }

  Future<void> _confirmPin() async {
    final first = _firstPin;
    if (first == null) {
      setState(() {
        _mode = _PinMode.create;
        _pin = '';
        _error = 'Start again.';
      });
      return;
    }
    if (_pin != first) {
      setState(() {
        _mode = _PinMode.create;
        _firstPin = null;
        _pin = '';
        _error = 'Those PINs did not match. Create it again.';
      });
      return;
    }

    setState(() => _submitting = true);
    final saved = await state.setPin(_pin);
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _submitting = false;
        _mode = _PinMode.create;
        _firstPin = null;
        _pin = '';
        _error = 'That PIN could not be saved. Try again.';
      });
      return;
    }
    // The new PIN must be entered once to prove it was stored, then it opens
    // the dashboard like any later relaunch would.
    setState(() {
      _submitting = false;
      _mode = _PinMode.unlock;
      _firstPin = null;
      _pin = '';
      _notice = 'PIN created. Enter it to unlock SurGo.';
    });
  }

  Future<void> _unlock() async {
    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
    });

    final result = await state.unlockWithPin(_pin);
    if (!mounted) return;

    if (result == PinUnlockResult.success) {
      _lockTimer?.cancel();
      Navigator.pushNamedAndRemoveUntil(
        context,
        state.requiresOnboarding ? '/onboarding' : state.homeRoute,
        (r) => false,
      );
      return;
    }

    _failedAttempts++;
    if (_failedAttempts >= _maxAttempts) {
      _startLockout();
      return;
    }
    final left = _maxAttempts - _failedAttempts;
    setState(() {
      _submitting = false;
      _pin = '';
      _error =
          'That PIN is incorrect. '
          '$left ${left == 1 ? 'attempt' : 'attempts'} left.';
    });
  }

  void _startLockout() {
    _lockTimer?.cancel();
    setState(() {
      _submitting = false;
      _pin = '';
      _lockedFor = _lockSeconds;
      _error = 'Too many incorrect attempts. Try again in ${_lockedFor}s.';
    });
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockedFor <= 1) {
        timer.cancel();
        setState(() {
          _lockedFor = 0;
          _failedAttempts = 0;
          _error = null;
        });
        return;
      }
      setState(() {
        _lockedFor--;
        _error = 'Too many incorrect attempts. Try again in ${_lockedFor}s.';
      });
    });
  }

  Future<void> _forgotPin() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    await state.forgotPin();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  Future<void> _signOut() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    await state.logout();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  void _startOver() {
    if (!_enabled) return;
    setState(() {
      _mode = _PinMode.create;
      _firstPin = null;
      _pin = '';
      _error = null;
    });
  }

  String get _title => switch (_mode) {
    _PinMode.create => 'Create your PIN',
    _PinMode.confirm => 'Confirm your PIN',
    _PinMode.unlock => 'Welcome back',
  };

  String get _subtitle => switch (_mode) {
    _PinMode.create =>
      'Choose a 6-digit PIN. It unlocks SurGo when the app reopens.',
    _PinMode.confirm => 'Enter the same 6 digits once more.',
    _PinMode.unlock => 'Enter your PIN to unlock your SurGo dashboard.',
  };

  @override
  Widget build(BuildContext context) {
    final account = state.currentAccount;
    final role = demoAccountRefFor(account?.id ?? '')?.roleLabel;

    return SbAuthScaffold(
      children: [
        const SizedBox(height: 22),
        const SbBrandLockup(),
        const SizedBox(height: 30),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          SbAuthHeader(
            title: _mode == _PinMode.unlock && account != null
                ? 'Welcome back, ${account.name.split(' ').first}'
                : _title,
            subtitle: _subtitle,
          ),
          if (account != null && role != null) ...[
            const SizedBox(height: 8),
            Text(
              '${account.name} · $role',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted2, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 28),
          _pinIndicators(),
          const SizedBox(height: 18),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _notice!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.primaryLight,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          SbAuthError(message: _error),
          const SizedBox(height: 6),
          Center(child: _keypad()),
          const SizedBox(height: 12),
          if (_mode == _PinMode.confirm)
            Center(
              child: TextButton(
                onPressed: _enabled ? _startOver : null,
                child: const Text('Start over'),
              ),
            )
          else
            Center(
              child: TextButton(
                onPressed: _submitting
                    ? null
                    : _mode == _PinMode.create
                    ? _signOut
                    : _forgotPin,
                child: Text(
                  _mode == _PinMode.create
                      ? 'Sign out'
                      : 'Forgot PIN? Sign in again',
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _pinIndicators() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(_length, (index) {
            final filled = index < _pin.length;
            final active = index == _pin.length && _enabled;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: 42,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _error != null
                      ? AppColors.danger
                      : active
                      ? AppColors.primary
                      : filled
                      ? AppColors.primary.withValues(alpha: 0.6)
                      : AppColors.borderLight,
                  width: active ? 1.8 : 1.2,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.22),
                          blurRadius: 14,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 160),
                scale: filled ? 1 : 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: AppColors.primaryLight,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _keypad() {
    Widget key(String label, {String? keyName, Widget? child}) {
      return SizedBox(
        width: 72,
        height: 60,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey(keyName ?? 'pin-key-$label'),
            borderRadius: BorderRadius.circular(18),
            onTap: _enabled ? () => _onDigit(label) : null,
            child: Ink(
              decoration: BoxDecoration(
                color: _enabled ? AppColors.panel : AppColors.panel2,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: Center(
                child:
                    child ??
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: _enabled ? AppColors.text : AppColors.muted2,
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
    }

    Widget row(List<Widget> children) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: children,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row([key('1'), key('2'), key('3')]),
          const SizedBox(height: 12),
          row([key('4'), key('5'), key('6')]),
          const SizedBox(height: 12),
          row([key('7'), key('8'), key('9')]),
          const SizedBox(height: 12),
          row([
            const SizedBox(width: 72, height: 60),
            key('0'),
            SizedBox(
              width: 72,
              height: 60,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('pin-key-backspace'),
                  borderRadius: BorderRadius.circular(18),
                  onTap: _enabled ? _onBackspace : null,
                  child: Center(
                    child: Icon(
                      Icons.backspace_outlined,
                      size: 21,
                      color: _enabled ? AppColors.muted : AppColors.muted2,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
