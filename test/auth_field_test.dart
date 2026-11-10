import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/phone_input.dart';
import 'package:surgo/theme/app_theme.dart';
import 'package:surgo/widgets/auth_widgets.dart';

void main() {
  testWidgets('the auth field label floats up on focus and back on blur',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SbAuthField(label: 'Phone number', controller: controller),
      ),
    ));

    final labelStyle = find.descendant(
      of: find.byType(SbAuthField),
      matching: find.byType(AnimatedDefaultTextStyle),
    );
    double labelSize() => tester
        .widgetList<AnimatedDefaultTextStyle>(labelStyle)
        .first
        .style
        .fontSize!;

    expect(labelSize(), 15);
    expect(find.text('Phone number'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 250));
    expect(labelSize(), 11);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 250));
    expect(labelSize(), 15);
  });

  testWidgets('a filled field keeps its label up after blur', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SbAuthField(label: 'Phone number', controller: controller),
      ),
    ));

    await tester.enterText(find.byType(TextField), '0917');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 250));

    final style = tester
        .widgetList<AnimatedDefaultTextStyle>(find.descendant(
          of: find.byType(SbAuthField),
          matching: find.byType(AnimatedDefaultTextStyle),
        ))
        .first
        .style;
    expect(style.fontSize, 11);
  });

  testWidgets('the field renders its inline error', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SbAuthField(
          label: 'Phone number',
          controller: controller,
          errorText: 'Enter a PH mobile number.',
        ),
      ),
    ));

    expect(find.text('Enter a PH mobile number.'), findsOneWidget);
  });

  test('the phone formatter inserts nothing and refuses letters', () {
    const oldValue = TextEditingValue.empty;

    final typed = phPhoneInputFormatter.formatEditUpdate(
      oldValue,
      const TextEditingValue(text: '09171234567'),
    );
    expect(typed.text, '09171234567');

    final pasted = phPhoneInputFormatter.formatEditUpdate(
      oldValue,
      const TextEditingValue(text: '+63 917 123 4567'),
    );
    expect(pasted.text, '+63 917 123 4567');

    final letters = phPhoneInputFormatter.formatEditUpdate(
      oldValue,
      const TextEditingValue(text: '0917abc'),
    );
    expect(letters, oldValue);
  });
}
