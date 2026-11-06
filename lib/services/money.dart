/// Every peso amount in SurGo is an integer number of **centavos**.
///
/// One peso is 100 centavos, so `₱180.50` is `18050`. Amounts are stored as
/// ints everywhere — seed data, model fields, ledger entries, wallet balances —
/// so commission arithmetic never touches a floating-point value and a split
/// always re-adds to the exact gross.
///
/// Two helpers keep the unit conversions honest:
///
///  * [Money.format] is the only way a screen should render an amount. Before
///    this class existed, screens hand-rolled `'₱${x}'`, which produced `₱180`
///    on one card while the receipt beside it printed `₱180.00`.
///  * [Money.tryParsePesos] converts a peso amount the user typed. It parses
///    the integer and fractional halves separately rather than going through
///    a `double`, so `1250.55` cannot drift by a centavo.
///
/// Authoring seed data and typing user input are the only two places that work
/// in pesos; everything else should already be centavos.
class Money {
  Money._();

  /// Centavos in one peso.
  static const int centavosPerPeso = 100;

  /// Currency symbol, centralised so it is defined in exactly one place.
  static const String symbol = '₱';

  /// Converts whole pesos to centavos. Use when authoring seed data or when
  /// crossing a pesos boundary — never to "fix up" an amount that is already
  /// in centavos.
  static int pesos(int wholePesos) => wholePesos * centavosPerPeso;

  /// Centavos expressed as pesos, for display-only maths such as chart axis
  /// labels. Do not feed the result back into an amount.
  static double toPesos(int centavos) => centavos / centavosPerPeso;

  /// Formats centavos as a peso amount with thousands separators and two
  /// decimal places, e.g. `₱1,234.50`.
  ///
  /// Set [symbol] to false for input fields and table columns that supply the
  /// peso sign separately.
  static String format(int centavos, {bool symbol = true}) {
    final negative = centavos < 0;
    final absolute = centavos.abs();
    final whole = absolute ~/ centavosPerPeso;
    final fraction = (absolute % centavosPerPeso).toString().padLeft(2, '0');
    final sign = negative ? '-' : '';
    return '$sign${symbol ? pesoSymbol : ''}${_group(whole)}.$fraction';
  }

  /// Formats with an explicit leading `+` or `-`, for wallet rows and any
  /// other place where the direction of the movement matters.
  static String signed(int centavos) => centavos < 0
      ? '-${format(centavos.abs())}'
      : '+${format(centavos)}';

  /// Parses a peso amount the user typed — `"1250"`, `"1,250.50"` or `"₱250"`
  /// all work — into centavos.
  ///
  /// Returns null for anything that is not a usable amount: blank text, more
  /// than one decimal point, non-numeric characters, or a value of zero or
  /// less. The integer and fractional halves are parsed independently instead
  /// of via a `double`, so no precision is lost on large amounts.
  static int? tryParsePesos(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;

    final parts = cleaned.split('.');
    if (parts.length > 2) return null;

    final whole = int.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    if (whole == null) return null;

    var fractionDigits = parts.length == 1 ? '' : parts[1];
    if (fractionDigits.length > 2) return null;
    fractionDigits = fractionDigits.padRight(2, '0');

    final centavos = whole * centavosPerPeso + int.parse(fractionDigits);
    return centavos <= 0 ? null : centavos;
  }

  /// Inserts thousands separators into a non-negative integer.
  static String _group(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Shorthand for the peso sign, so call sites read `Money.format(x)` without
/// needing `symbol:` in the common case.
const String pesoSymbol = Money.symbol;
