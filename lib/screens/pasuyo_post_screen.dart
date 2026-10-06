import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/location_picker.dart';
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

  PasuyoCategory _category = PasuyoCategory.groceries;
  String _pickup = '';
  String _pickupBarangay = '';
  String _pickupPurok = '';
  String _dropoff = '';
  String _dropoffBarangay = '';
  String _dropoffPurok = '';
  int _budget = 15000;

  /// Slider bounds in centavos: ₱50 to ₱800.
  static const int minBudget = 5000;
  static const int maxBudget = 80000;
  final List<String> _items = [];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _itemCtrl.dispose();
    _noteCtrl.dispose();
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

  void _addItem(String raw) {
    final item = raw.trim();
    if (item.isEmpty) return;
    setState(() {
      _items.add(item);
      _itemCtrl.clear();
    });
  }

  void _post() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_pickup.isEmpty || _dropoff.isEmpty) {
      _toast('Set both pickup and drop-off first');
      return;
    }
    if (_items.isEmpty) {
      _toast('Add at least one item');
      return;
    }

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
    );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: task.id)),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final breakdown = FeeCalculator.breakdownFor(ServiceType.pasuyo, _budget);

    return Scaffold(
      appBar: AppBar(title: const Text('Post a Pasuyo')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
          children: [
            const Text('What do you need?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primarySoft
                          : AppColors.panel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: selected ? AppColors.primary : AppColors.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(c.icon,
                            size: 15,
                            color: selected
                                ? AppColors.primaryLight
                                : AppColors.muted),
                        const SizedBox(width: 6),
                        Text(c.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: selected
                                  ? AppColors.primaryLight
                                  : AppColors.text,
                            )),
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
                children: _items.map((item) => SbChip(
                      item,
                      active: true,
                      onTap: () => setState(() => _items.remove(item)),
                    )).toList(),
              ),
            ],
            const SizedBox(height: 18),
            SbField(
              label: 'Pickup',
              value: _pickup.isEmpty ? 'Where should the helper buy it?' : _pickup,
              leading: const Icon(Icons.storefront_outlined,
                  size: 17, color: AppColors.secondary),
              onTap: () async {
                final picked = await showLocationPicker(context,
                    title: 'Pickup location');
                if (picked != null) _applyLocation(picked, isPickup: true);
              },
            ),
            const SizedBox(height: 8),
            SbField(
              label: 'Drop-off',
              value:
                  _dropoff.isEmpty ? 'Where should it go?' : _dropoff,
              leading: const Icon(Icons.place_outlined,
                  size: 17, color: AppColors.primary),
              onTap: () async {
                final picked = await showLocationPicker(context,
                    title: 'Drop-off location');
                if (picked != null) _applyLocation(picked, isPickup: false);
              },
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Text('Errand budget',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                const Spacer(),
                Text(Money.format(_budget),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
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
              label: 'Post Pasuyo · ${breakdown.customerPaysLabel}',
              icon: Icons.send_rounded,
              onPressed: _post,
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
          _row('Helper gets', b.providerGetsLabel,
              color: AppColors.secondaryLight),
          const SizedBox(height: 6),
          _row('SurGo service fee (15%)', b.surgoKeepsLabel,
              color: AppColors.yellow),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold ? AppColors.text : AppColors.muted,
              )),
        ),
        Text(value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: color ?? AppColors.text,
            )),
      ],
    );
  }
}
