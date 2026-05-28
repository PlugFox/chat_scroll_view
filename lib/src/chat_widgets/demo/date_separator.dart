import 'package:flutter/widgets.dart';

/// Day-separator pill for the demo chat.
///
/// One widget for both jobs: the inline divider above the first message of a
/// day, and the floating header pinned to the viewport top. The viewport fades
/// the inline copy out as it nears the floating one, so the two never collide
/// — the pill is free to carry its own padding.
class DateSeparator extends StatelessWidget {
  const DateSeparator({required this.date, super.key});

  /// A date within the day this separator labels.
  final DateTime date;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE0202124),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            _formatDay(date),
            style: const TextStyle(
              color: Color(0xFFE6E6E6),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}

const List<String> _months = <String>[
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

/// Formats [date] as a day label: "Сегодня" / "Вчера" / "5 мая" /
/// "5 мая 2024" (the year is shown only when it differs from the current one).
///
/// Works in the local time zone — to match the default `groupBy`, which
/// also groups by the local calendar day. A timestamp parsed from ISO 8601 is
/// UTC; without this conversion the label could disagree with the grouping
/// near midnight — two distinct day groups printing the very same date.
String _formatDay(DateTime date) {
  final local = date.toLocal();
  final now = DateTime.now();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  final label = '${local.day} ${_months[local.month - 1]}';
  return local.year == today.year ? label : '$label ${local.year}';
}
