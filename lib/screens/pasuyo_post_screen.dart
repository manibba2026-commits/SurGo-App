import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../data/db_models.dart';
import '../repositories/repository_failure.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/location_picker.dart';
import '../widgets/surgo_notice.dart';
import 'pasuyo_task_screen.dart';

/// "Post a Pasuyo" form. The customer picks a category, types what they need,
/// sets pickup and drop-off, and picks a budget. The service fee is derived
/// from the budget through FeeCalculator so it always matches the receipt.
class PasuyoPostScreen extends StatefulWidget {
  const PasuyoPostScreen({super.key});

  @override
  State<PasuyoPostScreen> createState() => _PasuyoPostScreenState();
}

class _PasuyoPostScreenState extends State<PasuyoPostScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _itemCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _recipientNameCtrl = TextEditingController();
  final _recipientPhoneCtrl = TextEditingController();

  PasuyoCategory _category = PasuyoCategory.groceries;
  String _pickup = '';
  String _pickupBarangay = '';
  String _pickupPurok = '';
  String _dropoff = '';
  String _dropoffBarangay = '';
  String _dropoffPurok = '';
  String? _pickupBarangayId;
  String? _pickupPurokId;
  String? _dropoffBarangayId;
  String? _dropoffPurokId;
  bool _bookedForSomeone = false;
  bool _submitting = false;
  int _budget = 15000;

  /// Hosted writes go straight to Postgres and need the barangay id, while the
  /// seeded demo keeps using AppState and its label-only picker.
  bool get _hosted =>
      AppState.instance.usesHostedIdentity &&
      AppState.instance.repositories.isSupabaseBacked;

  /// Slider bounds in centavos: ₱50 to ₱800.
  static const int minBudget = 5000;
  static const int maxBudget = 80000;
  final List<String> _items = [];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _itemCtrl.dispose();
    _noteCtrl.dispose();
    _recipientNameCtrl.dispose();
    _recipientPhoneCtrl.dispose();
    super.dispose();
  }

  /// The label the location picker hands back is "Purok 3, San Isidro" — split
  /// it so the task stores barangay and purok separately like every other
  /// request in the app.
  void _applyLocation(String label, {required bool isPickup}) {
    final parts = label.split(',').map((p) => p.trim()).toList();
    final purok = parts.isNotEmpty ? parts.first : '';
    final barangay = parts.length > 1 ? parts[1] : '';
    setState(() {
      if (isPickup) {
        _pickup = label;
        _pickupPurok = purok;
        _pickupBarangay = barangay;
      } else {
        _dropoff = label;
        _dropoffPurok = purok;
        _dropoffBarangay = barangay;
      }
    });
  }

  /// Hosted variant: keeps the chosen barangay and purok ids so the database
  /// row can reference them instead of a free-text label.
  void _applyHostedLocation(PickedLocation picked, {required bool isPickup}) {
    setState(() {
      if (isPickup) {
        _pickup = picked.label;
        _pickupBarangay = picked.barangayName;
        _pickupPurok = picked.purokName ?? '';
        _pickupBarangayId = picked.barangayId;
        _pickupPurokId = picked.purokId;
      } else {
        _dropoff = picked.label;
        _dropoffBarangay = picked.barangayName;
        _dropoffPurok = picked.purokName ?? '';
        _dropoffBarangayId = picked.barangayId;
        _dropoffPurokId = picked.purokId;
      }
    });
  }

  Future<void> _pickLocation({required bool isPickup}) async {
    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    bool current() =>
        mounted &&
        identical(registry, state.repositories) &&
        userId == state.identity?.userId;
    if (!_hosted) {
      final picked = await showLocationPicker(
        context,
        title: isPickup ? 'Pickup location' : 'Drop-off location',
      );
      if (current() && picked != null) {
        _applyLocation(picked, isPickup: isPickup);
      }
      return;
    }
    final picked = await showHostedLocationPicker(
      context,
      title: isPickup ? 'Pickup location' : 'Drop-off location',
    );
    if (current() && picked != null) {
      _applyHostedLocation(picked, isPickup: isPickup);
    }
  }

  void _addItem(String raw) {
    final item = raw.trim();
    if (item.isEmpty) return;
    setState(() {
      _items.add(item);
      _itemCtrl.clear();
    });
  }

  Future<void> _post() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_pickup.isEmpty || (_hosted && _pickupBarangayId == null)) {
      _toast('Set both pickup and drop-off first');
      return;
    }
    if (_dropoff.isEmpty || (_hosted && _dropoffBarangayId == null)) {
      _toast('Set both pickup and drop-off first');
      return;
    }
    if (_items.isEmpty) {
      _toast('Add at least one item');
      return;
    }
    if (_bookedForSomeone && _recipientNameCtrl.text.trim().isEmpty) {
      _toast('Add the recipient\'s name');
      return;
    }

    setState(() => _submitting = true);
    if (!_hosted) {
      final task = AppState.instance.postPasuyoTask(
        category: _category,
        title: _titleCtrl.text.trim(),
        items: List.unmodifiable(_items),
        pickupBarangay: _pickupBarangay,
        pickupPurok: _pickupPurok,
        pickup: _pickup,
        dropoffBarangay: _dropoffBarangay,
        dropoffPurok: _dropoffPurok,
        dropoff: _dropoff,
        budget: _budget,
        note: _noteCtrl.text.trim(),
        bookedForSomeone: _bookedForSomeone,
        recipientName: _recipientNameCtrl.text.trim(),
        recipientPhone: normalizePhoneNumber(_recipientPhoneCtrl.text) ?? '',
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: task.id)),
      );
      return;
    }

    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    final accountId = state.currentAccount?.id;
    bool current() =>
        mounted &&
        _hosted &&
        identical(registry, state.repositories) &&
        userId == state.identity?.userId &&
        accountId == state.currentAccount?.id &&
        state.isSignedIn;
    try {
      if (!current()) {
        _toast('Sign in again before posting an errand.');
        return;
      }
      final note = _noteCtrl.text.trim();
      final phone = normalizePhoneNumber(_recipientPhoneCtrl.text) ?? '';
      final task = await AppState.instance.createHostedErrand(
        category: _category,
        title: _titleCtrl.text.trim(),
        pickupAddress: _pickup,
        pickupBarangayId: _pickupBarangayId!,
        pickupPurokId: _pickupPurokId,
        quotedFeeCentavos: _budget,
        items: [
          for (final item in _items) {'name': item},
        ],
        description: note.isEmpty ? null : note,
        dropoffAddress: _dropoff,
        dropoffBarangayId: _dropoffBarangayId,
        dropoffPurokId: _dropoffPurokId,
        bookedForSomeone: _bookedForSomeone,
        recipientName: _bookedForSomeone
            ? _recipientNameCtrl.text.trim()
            : null,
        recipientPhone: _bookedForSomeone && phone.isNotEmpty ? phone : null,
      );
      if (!mounted || !current()) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: task.id)),
      );
    } on RepositoryFailure catch (failure) {
      if (current()) _toast(failure.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String message) {
    SurgoNotice.show(context, message, tone: SbNoticeTone.warning);
  }

  @override
  Widget build(BuildContext context) {
    // Hosted errands charge a flat platform add-on and pay the helper the fee
    // whole; the seeded demo still uses the legacy percentage split.
    final breakdown = _hosted
        ? FeeBreakdown.fixedAddon(
            service: ServiceType.pasuyo,
            providerFare: _budget,
            platformFee: HostedFees.pasuyoPlatformFeeCentavos,
          )
        : FeeCalculator.breakdownFor(ServiceType.pasuyo, _budget);

    return Scaffold(
      appBar: AppBar(title: const Text('Post a Pasuyo')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
          children: [
            const Text(
              'What do you need?',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: PasuyoCategory.values.map((c) {
                final selected = c == _category;
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _category = c),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primarySoft : AppColors.panel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? AppColors.primary : AppColors.border,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          c.icon,
                          size: 15,
                          color: selected
                              ? AppColors.primaryLight
                              : AppColors.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          c.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? AppColors.primaryLight
                                : AppColors.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _titleCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Short description',
                hintText: 'e.g. Buy 2 Chickenjoy from Jollibee',
                labelStyle: TextStyle(fontSize: 12.5),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Add a description' : null,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _itemCtrl,
                    style: const TextStyle(fontSize: 13),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: _addItem,
                    decoration: const InputDecoration(
                      labelText: 'Item',
                      hintText: '2x Chickenjoy',
                      labelStyle: TextStyle(fontSize: 12.5),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SbIconButton(
                  icon: Icons.add_rounded,
                  onTap: () => _addItem(_itemCtrl.text),
                  color: AppColors.primaryLight,
                ),
              ],
            ),
            if (_items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: _items
                    .map(
                      (item) => SbChip(
                        item,
                        active: true,
                        onTap: () => setState(() => _items.remove(item)),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 18),
            SbField(
              label: 'Pickup',
              value: _pickup.isEmpty
                  ? 'Where should the helper buy it?'
                  : _pickup,
              leading: const Icon(
                Icons.storefront_outlined,
                size: 17,
                color: AppColors.secondary,
              ),
              onTap: () => _pickLocation(isPickup: true),
            ),
            const SizedBox(height: 8),
            SbField(
              label: 'Drop-off',
              value: _dropoff.isEmpty ? 'Where should it go?' : _dropoff,
              leading: const Icon(
                Icons.place_outlined,
                size: 17,
                color: AppColors.primary,
              ),
              onTap: () => _pickLocation(isPickup: false),
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Booked for someone else',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
              subtitle: const Text(
                'The recipient receives the goods; you still pay.',
                style: TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
              value: _bookedForSomeone,
              activeTrackColor: AppColors.primary,
              onChanged: (v) => setState(() => _bookedForSomeone = v),
            ),
            if (_bookedForSomeone) ...[
              const SizedBox(height: 4),
              TextFormField(
                controller: _recipientNameCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Recipient name',
                  labelStyle: TextStyle(fontSize: 12.5),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    !_bookedForSomeone || (v != null && v.trim().isNotEmpty)
                    ? null
                    : 'Add the recipient\'s name',
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _recipientPhoneCtrl,
                keyboardType: TextInputType.phone,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Recipient phone (optional)',
                  labelStyle: TextStyle(fontSize: 12.5),
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value == null ||
                        value.trim().isEmpty ||
                        normalizePhoneNumber(value) != null
                    ? null
                    : 'Enter a valid recipient phone number.',
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const Text(
                  'Errand budget',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
                const Spacer(),
                Text(
                  Money.format(_budget),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            Slider(
              // The slider works in centavos directly, so no pesos-to-centavos
              // conversion happens on every drag frame.
              value: _budget.toDouble().clamp(minBudget, maxBudget).toDouble(),
              min: minBudget.toDouble(),
              max: maxBudget.toDouble(),
              divisions: 30,
              activeColor: AppColors.secondary,
              inactiveColor: AppColors.panel3,
              onChanged: (v) => setState(() => _budget = v.round()),
            ),
            _feePreview(breakdown),
            const SizedBox(height: 18),
            TextFormField(
              controller: _noteCtrl,
              maxLines: 2,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                labelText: 'Note for the helper (optional)',
                labelStyle: TextStyle(fontSize: 12.5),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SbPrimaryButton(
              label: _submitting
                  ? 'Posting…'
                  : 'Post Pasuyo · ${breakdown.customerPaysLabel}',
              icon: Icons.send_rounded,
              onPressed: _submitting ? null : _post,
            ),
          ],
        ),
      ),
    );
  }

  /// Shows the same three-way split the receipt will show, so the customer
  /// sees the fee before posting rather than after.
  Widget _feePreview(FeeBreakdown b) {
    return SbCard(
      child: Column(
        children: [
          _row('Customer pays', b.customerPaysLabel, bold: true),
          const SizedBox(height: 6),
          _row(
            'Helper gets',
            b.providerGetsLabel,
            color: AppColors.secondaryLight,
          ),
          const SizedBox(height: 6),
          _row(
            _hosted ? 'Platform fee (fixed)' : 'SurGo service fee (15%)',
            b.surgoKeepsLabel,
            color: AppColors.yellow,
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              color: bold ? AppColors.text : AppColors.muted,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: color ?? AppColors.text,
          ),
        ),
      ],
    );
  }
}
