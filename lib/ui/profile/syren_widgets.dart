import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../app_feedback.dart';
import '../syren_theme.dart';

Color personColor(Person person) => person.colorIndex < 0
    ? SyrenColors.guest
    : SyrenColors.people[person.colorIndex % SyrenColors.people.length];

/// Turns a thrown error into a sentence for people.
String friendlyError(Object error) => error.toString().replaceFirst(
  RegExp(r'^(Bad state|Exception|StateError): '),
  '',
);

/// Shared busy flag and error snack bar for pages that send commands.
mixin CommandRunner<T extends StatefulWidget> on State<T> {
  bool busy = false;

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        showLatestSnackBar(
          context,
          SnackBar(content: Text(friendlyError(error))),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

/// A scrolling page with the design's side padding and a readable width.
class SyrenPage extends StatelessWidget {
  const SyrenPage({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(18, 6, 18, 28),
    this.spacing = 14,
  });

  final List<Widget> children;
  final EdgeInsets padding;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView.separated(
            padding: padding,
            itemCount: children.length,
            separatorBuilder: (context, index) => SizedBox(height: spacing),
            itemBuilder: (context, index) => children[index],
          ),
        ),
      ),
    );
  }
}

/// Large page title with an optional line under it and a trailing widget.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: SyrenText.title),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: SyrenText.small.copyWith(fontSize: 14),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// The "‹ Home" link at the top of pushed pages.
class BackLink extends StatelessWidget {
  const BackLink(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.of(context).maybePop(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(
              '‹ $label',
              style: SyrenText.body.copyWith(
                color: SyrenColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

class SyrenCard extends StatelessWidget {
  const SyrenCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    this.color = SyrenColors.card,
    this.radius = 18,
    this.onTap,
    this.border,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final double radius;
  final VoidCallback? onTap;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return Material(
      color: color,
      borderRadius: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: border == null
              ? null
              : BoxDecoration(border: border, borderRadius: shape),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

/// A card of rows split by thin lines.
class RowsCard extends StatelessWidget {
  const RowsCard({
    super.key,
    required this.rows,
    this.color = SyrenColors.card,
  });

  final List<Widget> rows;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SyrenCard(
      padding: EdgeInsets.zero,
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, row) in rows.indexed) ...[
            if (index > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: SyrenColors.divider,
              ),
            row,
          ],
        ],
      ),
    );
  }
}

/// One line in a [RowsCard] with a label on the left and a value on the right.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    this.value,
    this.valueColor,
    this.bold = false,
    this.onTap,
    this.background,
  });

  final String label;
  final String? value;
  final Color? valueColor;
  final bool bold;
  final VoidCallback? onTap;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  label,
                  style: SyrenText.body.copyWith(
                    fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value!,
                    textAlign: TextAlign.right,
                    style: SyrenText.body.copyWith(
                      fontSize: 14,
                      color: valueColor ?? SyrenColors.muted,
                      fontWeight: valueColor == null
                          ? FontWeight.w400
                          : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small uppercase label in the mono font.
class MonoLabel extends StatelessWidget {
  const MonoLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Text(
        text.toUpperCase(),
        style: SyrenText.mono.copyWith(color: color),
      ),
    );
  }
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar(this.person, {super.key, this.size = 38});

  final Person person;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: personColor(person),
        shape: BoxShape.circle,
      ),
      child: Text(
        person.initial,
        style: TextStyle(
          fontFamily: SyrenFonts.sans,
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
          height: 1,
        ),
      ),
    );
  }
}

/// A rounded tag, like "Follow me" or "Offline".
class StatusChip extends StatelessWidget {
  const StatusChip(
    this.text, {
    super.key,
    this.background = SyrenColors.divider,
    this.foreground = SyrenColors.subtle,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: SyrenFonts.sans,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

enum ButtonKind { primary, outline, link, spotify }

class SyrenButton extends StatelessWidget {
  const SyrenButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.kind = ButtonKind.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final ButtonKind kind;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    if (kind == ButtonKind.link) {
      return TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(foregroundColor: SyrenColors.muted),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: SyrenFonts.sans,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.underline,
            decorationColor: SyrenColors.muted,
          ),
        ),
      );
    }
    final (background, foreground) = switch (kind) {
      ButtonKind.spotify => (SyrenColors.spotify, const Color(0xFF0B0B0B)),
      ButtonKind.outline => (Colors.transparent, SyrenColors.ink),
      _ => (SyrenColors.ink, Colors.white),
    };
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: background,
        shape: StadiumBorder(
          side: kind == ButtonKind.outline
              ? const BorderSide(color: SyrenColors.ink, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: SyrenFonts.sans,
                fontSize: 15,
                fontWeight: kind == ButtonKind.spotify
                    ? FontWeight.w700
                    : FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin level bar that can be dragged, with the value in mono on the right.
class LevelSlider extends StatefulWidget {
  const LevelSlider({
    super.key,
    required this.value,
    this.onChanged,
    this.color = SyrenColors.ink,
    this.label,
    this.suffix = '',
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final Color color;
  final String? label;
  final String suffix;

  @override
  State<LevelSlider> createState() => _LevelSliderState();
}

class _LevelSliderState extends State<LevelSlider> {
  double? dragging;

  @override
  Widget build(BuildContext context) {
    final shown = (dragging ?? widget.value).clamp(0, 100).toDouble();
    return Row(
      children: [
        if (widget.label != null)
          SizedBox(
            width: 72,
            child: Text(
              widget.label!,
              style: SyrenText.small.copyWith(
                color: SyrenColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: widget.color,
              thumbColor: widget.color,
              disabledActiveTrackColor: SyrenColors.faint,
              disabledThumbColor: SyrenColors.faint,
            ),
            child: Slider(
              value: shown,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
              max: 100,
              semanticFormatterCallback: (value) => '${value.round()}',
              onChanged: widget.onChanged == null
                  ? null
                  : (value) {
                      setState(() => dragging = value);
                      widget.onChanged!(value);
                    },
              onChangeEnd: widget.onChanged == null
                  ? null
                  : (value) {
                      widget.onChanged!(value);
                      setState(() => dragging = null);
                    },
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '${shown.round()}${widget.suffix}',
            textAlign: TextAlign.right,
            style: SyrenText.mono.copyWith(fontSize: 12, letterSpacing: 0),
          ),
        ),
      ],
    );
  }
}

/// A row of options on a grey track, with the chosen one filled dark.
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final Map<T, String> options;
  final T value;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: SyrenColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final entry in options.entries)
            Expanded(
              child: Semantics(
                selected: entry.key == value,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onChanged == null || entry.key == value
                      ? null
                      : () => onChanged!(entry.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: entry.key == value
                          ? SyrenColors.ink
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      entry.value,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: SyrenFonts.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: entry.key == value
                            ? Colors.white
                            : SyrenColors.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A card row with a title, a line under it and a switch.
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: SyrenText.label),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: SyrenText.small),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// A grey box with a short explanation, like the design's "i" notes.
class NoteBox extends StatelessWidget {
  const NoteBox(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: SyrenColors.divider,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'i',
            style: TextStyle(
              fontFamily: SyrenFonts.sans,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: SyrenColors.subtle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: SyrenText.small.copyWith(color: SyrenColors.subtle),
            ),
          ),
        ],
      ),
    );
  }
}
