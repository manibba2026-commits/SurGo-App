import 'package:flutter/services.dart';

import 'auth_models.dart';

/// Keeps phone fields to phone characters: digits, one leading `+`, and the
/// separators people paste in. Nothing is ever inserted automatically, and an
/// invalid keystroke is ignored rather than rewriting the value under the
/// cursor. [normalizePhoneNumber] strips the separators on submit.
final TextInputFormatter phPhoneInputFormatter =
    TextInputFormatter.withFunction((oldValue, newValue) {
  final text = newValue.text;
  if (text.isEmpty) return newValue;
  if (!RegExp(r'^\+?[0-9 ()\-]*$').hasMatch(text)) return oldValue;
  if (text.length > 18) return oldValue;
  return newValue;
});

/// Validation message for a PH mobile field, or null when it is usable.
String? phoneFieldError(String raw) {
  if (raw.trim().isEmpty) return 'Enter your phone number.';
  if (normalizePhoneNumber(raw) == null) {
    return 'Enter a PH mobile number, for example 0917 123 4567 or +639171234567.';
  }
  return null;
}
