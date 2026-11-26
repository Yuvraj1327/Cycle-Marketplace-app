import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../utils/format.dart';

/// Primary action button with built-in busy state (disabled while the request is in flight, so double-submits are impossible).
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.icon,
    this.danger = false,
    this.outlined = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy, danger, outlined;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final child = busy
        ? SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: outlined ? context.palette.primary : Colors.white,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          );
    final cb = busy ? null : onPressed;
    if (outlined) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: danger ? AppColors.danger : context.palette.primary,
          side: BorderSide(
            color: danger ? AppColors.danger : context.palette.primary,
          ),
        ),
        onPressed: cb,
        child: child,
      );
    }
    return FilledButton(
      style: danger
          ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
          : null,
      onPressed: cb,
      child: child,
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color,
    this.onTap,
    this.caption,
  });
  final String label, value;
  final String? caption;
  final IconData icon;
  final Color? color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? context.palette.primary;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, size: 18, color: color),
                  ),
                  const Spacer(),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: context.palette.muted,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                label,
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
              if (caption != null)
                Text(
                  caption!,
                  style: TextStyle(color: context.palette.muted, fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal bar chart of REAL counts (never invented values). Bars are scaled to the largest value; zero rows still show their label.
class CountBars extends StatelessWidget {
  const CountBars({super.key, required this.rows});
  final List<({String label, int value, Color color})> rows;
  @override
  Widget build(BuildContext context) {
    final max = rows.fold<int>(0, (m, r) => r.value > m ? r.value : m);
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 108,
                  child: Text(r.label, style: const TextStyle(fontSize: 12.5)),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Stack(
                      children: [
                        Container(
                          height: 12,
                          decoration: BoxDecoration(
                            color: context.palette.line,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 12,
                          width: max == 0 ? 0 : c.maxWidth * r.value / max,
                          decoration: BoxDecoration(
                            color: r.color,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${r.value}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.all(14),
  });
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

class InfoRow extends StatelessWidget {
  const InfoRow(
    this.label,
    this.value, {
    super.key,
    this.bold = false,
    this.color,
  });
  final String label, value;
  final bool bold;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            label,
            style: TextStyle(color: context.palette.muted, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class AmountRow extends StatelessWidget {
  const AmountRow(
    this.label,
    this.amount, {
    super.key,
    this.bold = false,
    this.negative = false,
    this.color,
  });
  final String label;
  final num amount;
  final bool bold, negative;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          '${negative ? '− ' : ''}${money(amount)}',
          style: TextStyle(
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    ),
  );
}

/// Horizontal filter chips (server-side filters: each selection reloads from the backend).
class FilterChips<T> extends StatelessWidget {
  const FilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 8,
      ),
      children: [
        for (final o in options)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(o.$2),
              selected: selected == o.$1,
              onSelected: (_) => onSelected(o.$1),
            ),
          ),
      ],
    ),
  );
}

class SearchField extends StatefulWidget {
  const SearchField({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;
  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 8, AppSpacing.lg, 0),
    child: TextField(
      controller: _c,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            _c.clear();
            widget.onChanged('');
          },
        ),
      ),
      onSubmitted: widget.onChanged,
    ),
  );
}

class StatusBanner extends StatelessWidget {
  const StatusBanner(
    this.text, {
    super.key,
    this.color = AppColors.warning,
    this.icon = Icons.info_outline,
  });
  final String text;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    width: double.infinity,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .3)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// "All time" / chosen calendar-day range. The range is sent to the backend (date_from/date_to), never applied on the device.
class DateRangeBar extends StatelessWidget {
  const DateRangeBar({super.key, required this.range, required this.onChanged});
  final DateTimeRange? range;
  final ValueChanged<DateTimeRange?> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 4, AppSpacing.lg, 0),
    child: Row(
      children: [
        ActionChip(
          avatar: const Icon(Icons.date_range, size: 18),
          label: Text(
            range == null
                ? 'All time'
                : '${dateShort(range!.start)} – ${dateShort(range!.end)}',
          ),
          onPressed: () async {
            final now = DateTime.now();
            final r = await showDateRangePicker(
              context: context,
              firstDate: DateTime(now.year - 3),
              lastDate: now,
              initialDateRange: range,
            );
            if (r != null) onChanged(r);
          },
        ),
        if (range != null)
          IconButton(
            tooltip: 'Clear dates',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => onChanged(null),
          ),
      ],
    ),
  );
}
