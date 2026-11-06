import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class PaymentMethodsScreen extends StatelessWidget {
  const PaymentMethodsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Methods')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              ...state.paymentMethods.map((m) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SbCard(
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.panel2,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(m.icon, size: 18, color: AppColors.primaryLight),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(m.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                    if (m.isDefault) ...[
                                      const SizedBox(width: 6),
                                      const SbTag('Default'),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(m.detail, style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            color: AppColors.panel2,
                            icon: const Icon(Icons.more_vert, color: AppColors.muted, size: 18),
                            onSelected: (v) {
                              if (v == 'default') state.setDefaultPaymentMethod(m);
                              if (v == 'remove') state.removePaymentMethod(m);
                            },
                            itemBuilder: (_) => [
                              if (!m.isDefault)
                                const PopupMenuItem(value: 'default', child: Text('Set as default')),
                              if (m.type != 'cash')
                                const PopupMenuItem(value: 'remove', child: Text('Remove')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 6),
              SbOutlineButton(
                label: 'Add Payment Method',
                icon: Icons.add,
                onPressed: () => _showAddSheet(context, state),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAddSheet(BuildContext context, AppState state) {
    final options = [
      ('gcash', 'GCash'),
      ('maya', 'Maya'),
      ('card', 'Debit/Credit Card'),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Link a payment method', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 14),
            ...options.map((o) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SbOutlineButton(
                    label: o.$2,
                    onPressed: () {
                      Navigator.pop(context);
                      state.addPaymentMethod(PaymentMethodItem(
                        id: 'pm${DateTime.now().microsecondsSinceEpoch}',
                        type: o.$1,
                        label: o.$2,
                        detail: 'Linked just now (simulated)',
                        isDefault: false,
                      ));
                    },
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
