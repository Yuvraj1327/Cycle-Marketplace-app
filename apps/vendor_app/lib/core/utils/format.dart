import 'package:intl/intl.dart';

final _money = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);
final _moneyWhole = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 0,
);

/// ₹1,23,456.50 (Indian grouping). Whole rupees are shown without decimals.
String money(num value) => value == value.roundToDouble()
    ? _moneyWhole.format(value)
    : _money.format(value);

String dateShort(DateTime? d) =>
    d == null ? '' : DateFormat('d MMM yyyy').format(d.toLocal());
String dateTime(DateTime? d) =>
    d == null ? '' : DateFormat('d MMM yyyy, h:mm a').format(d.toLocal());
String dayLabel(DateTime d) => DateFormat('EEE, d MMM').format(d);
String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// "10:00" -> "10:00 AM"
String time12(String? hhmm) {
  if (hhmm == null || hhmm.length < 5) return hhmm ?? '';
  final parts = hhmm.split(':');
  final h = int.tryParse(parts[0]) ?? 0;
  final m = parts[1].substring(0, 2);
  final suffix = h >= 12 ? 'PM' : 'AM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m $suffix';
}

String humanize(String snake) => snake.isEmpty
    ? snake
    : snake
          .split('_')
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
