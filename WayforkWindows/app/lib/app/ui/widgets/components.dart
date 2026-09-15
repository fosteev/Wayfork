import 'dart:math';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/core/app/latency_format.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/app/traffic_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/tunnel.dart';

/// Green filled / grey hollow / orange half / red cross
/// (docs/design/02-ux.md, "Status glyphs"), painted rather than composed from
/// icons so the four states line up on the same 10 px baseline.
class StatusGlyphView extends StatelessWidget {
  const StatusGlyphView({required this.glyph, this.size = 10, super.key});

  final StatusGlyph glyph;
  final double size;

  @override
  Widget build(BuildContext context) {
    final resources = FluentTheme.of(context).resources;
    return Semantics(
      label: switch (glyph) {
        StatusGlyph.up => 'connected',
        StatusGlyph.idle => 'inactive',
        StatusGlyph.transitioning => 'connecting',
        StatusGlyph.failed => 'failed',
        StatusGlyph.group => 'group',
      },
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(
          glyph: glyph,
          up: resources.systemFillColorSuccess,
          idle: resources.textFillColorTertiary,
          transitioning: resources.systemFillColorCaution,
          failed: resources.systemFillColorCritical,
          cross: resources.textOnAccentFillColorPrimary,
          accent: FluentTheme.of(context).accentColor,
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyph,
    required this.up,
    required this.idle,
    required this.transitioning,
    required this.failed,
    required this.cross,
    required this.accent,
  });

  final StatusGlyph glyph;
  final Color up;
  final Color idle;
  final Color transitioning;
  final Color failed;
  final Color cross;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    switch (glyph) {
      case StatusGlyph.up:
        canvas.drawCircle(center, radius, Paint()..color = up);
      case StatusGlyph.idle:
        canvas.drawCircle(center, radius - 0.6, _stroke(idle));
      case StatusGlyph.transitioning:
        canvas.drawCircle(center, radius - 0.6, _stroke(transitioning));
        // The right half filled, as on macOS: readable at 10 px, unlike a
        // spinner.
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius - 0.6),
          -pi / 2,
          pi,
          true,
          Paint()..color = transitioning,
        );
      case StatusGlyph.failed:
        canvas.drawCircle(center, radius, Paint()..color = failed);
        final arm = radius * 0.42;
        final pen = Paint()
          ..color = cross
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          center - Offset(arm, arm),
          center + Offset(arm, arm),
          pen,
        );
        canvas.drawLine(
          center - Offset(arm, -arm),
          center + Offset(arm, -arm),
          pen,
        );
      case StatusGlyph.group:
        // Accent square instead of the status dot (F16).
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: center,
              width: size.width,
              height: size.height,
            ),
            Radius.circular(size.width * 0.25),
          ),
          Paint()..color = accent,
        );
    }
  }

  Paint _stroke(Color color) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.up != up ||
      old.failed != failed ||
      old.accent != accent;
}

/// `OpenVPN` / `VLESS` pill.
class TypeBadge extends StatelessWidget {
  const TypeBadge({required this.kind, super.key});

  final TunnelKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.resources.controlAltFillColorSecondary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        StatusText.typeBadge(kind),
        style: theme.typography.caption?.copyWith(
          color: theme.resources.textFillColorSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// `↓ 1.2 MB/s ↑ 85 KB/s` with the session totals as the tooltip; `↓ — ↑ —`
/// without a fresh sample (F9). Tabular figures keep the row from jittering.
class RateLabel extends StatelessWidget {
  const RateLabel({required this.counters, super.key});

  final TrafficCounters? counters;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final idle = counters == null || counters!.isIdle;
    return Tooltip(
      message: counters == null
          ? TrafficFormat.staleTooltip
          : TrafficFormat.tooltip(counters!),
      child: Text(
        TrafficFormat.rateLabel(counters),
        maxLines: 1,
        style: theme.typography.caption?.copyWith(
          color: idle
              ? theme.resources.textFillColorTertiary
              : theme.resources.textFillColorSecondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The white (or dark) box with a hairline border the grouped lists sit in.
class GroupCard extends StatelessWidget {
  const GroupCard({required this.children, super.key});

  /// Rows; a divider is drawn between them.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final resources = FluentTheme.of(context).resources;
    return Container(
      decoration: BoxDecoration(
        color: resources.cardBackgroundFillColorDefault,
        border: Border.all(color: resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0)
              Divider(
                style: DividerThemeData(horizontalMargin: EdgeInsets.zero),
              ),
            children[index],
          ],
        ],
      ),
    );
  }
}

/// The `Dashboard` / `Tunnels` heading of a page.
class PageTitle extends StatelessWidget {
  const PageTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: FluentTheme.of(context).typography.subtitle);
}

/// Secondary body text — the shade every hint, detail line and caption uses.
class SecondaryText extends StatelessWidget {
  const SecondaryText(
    this.text, {
    this.color,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    super.key,
  });

  final String text;
  final Color? color;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Text(
      text,
      maxLines: maxLines,
      overflow: overflow,
      style: theme.typography.caption?.copyWith(
        color: color ?? theme.resources.textFillColorSecondary,
      ),
    );
  }
}

/// A yes/no dialog: the Win32 counterpart of the macOS `Alerts.show` with two
/// buttons. True when the user picked [confirm].
Future<bool> showQuestionDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  String cancel = 'Cancel',
  bool destructive = false,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 460),
      title: Text(title),
      content: Text(message),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancel),
        ),
        FilledButton(
          style: destructive
              ? ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(
                    FluentTheme.of(context).resources.systemFillColorCritical,
                  ),
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// A small rounded label next to a name: `2 rules`, `paused`, `shadowed`.
/// [tint] colours the text and the background of the ones that carry a
/// warning; the tooltip says why.
class Chip extends StatelessWidget {
  const Chip(this.text, {this.tint, this.tooltip, super.key});

  final String text;
  final Color? tint;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final tint = this.tint;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tint == null
            ? theme.resources.controlAltFillColorSecondary
            : tint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: theme.typography.caption?.copyWith(
          color: tint ?? theme.resources.textFillColorSecondary,
        ),
      ),
    );
    final message = tooltip;
    return message == null ? chip : Tooltip(message: message, child: chip);
  }
}

/// A field with the validation message the model returned under it.
class FieldWithError extends StatelessWidget {
  const FieldWithError({required this.child, this.error, super.key});

  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      child,
      if (error case final message?)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SecondaryText(
            message,
            color: FluentTheme.of(context).resources.systemFillColorCritical,
            maxLines: 2,
          ),
        ),
    ],
  );
}

/// Addresses, hashes and URIs: fixed width so they line up and do not reflow.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.typography.caption?.copyWith(
        fontFamily: 'Consolas',
        color: theme.resources.textFillColorSecondary,
      ),
    );
  }
}

/// Accent marker next to a name: `Default`, `Group`.
class AccentBadge extends StatelessWidget {
  const AccentBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.typography.caption?.copyWith(
          color: theme.accentColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Text colours for the latency bands (F14): darker than the status dots so
/// they read on white, lighter in dark mode.
Color bandColor(BuildContext context, LatencyBand band) {
  final dark = FluentTheme.of(context).brightness == Brightness.dark;
  return switch (band) {
    LatencyBand.good =>
      dark ? const Color(0xFF30D158) : const Color(0xFF1F8F3D),
    LatencyBand.fair =>
      dark ? const Color(0xFFFFB340) : const Color(0xFFA85900),
    LatencyBand.poor =>
      dark ? const Color(0xFFFF6961) : const Color(0xFFD1332B),
  };
}

/// `62 ms` in the band colour, or the red words when the tunnel is unreachable;
/// `—` while no probe has answered yet (F14).
class LatencyLabel extends StatelessWidget {
  const LatencyLabel({required this.sample, this.fontSize = 13, super.key});

  final LatencySample? sample;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final sample = this.sample;
    final Widget child;
    if (sample != null && sample.unreachable) {
      child = Text(
        'Not reachable',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: theme.resources.systemFillColorCritical,
        ),
      );
    } else if (sample != null && sample.milliseconds != null) {
      final color = bandColor(context, LatencyBand.of(sample.milliseconds!));
      child = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${sample.milliseconds}',
              style: TextStyle(fontWeight: FontWeight.w500, color: color),
            ),
            TextSpan(
              text: ' ms',
              style: TextStyle(fontSize: fontSize - 3, color: color),
            ),
          ],
        ),
        style: TextStyle(
          fontSize: fontSize,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    } else {
      child = Text(
        '—',
        style: TextStyle(
          fontSize: fontSize,
          color: theme.resources.textFillColorTertiary,
        ),
      );
    }
    return Tooltip(
      message: sample == null
          ? 'Measured through the tunnel every ${LatencyProbe.interval.inSeconds} s'
          : LatencyFormat.tooltip(sample),
      child: child,
    );
  }
}

/// Last 2 minutes of probes, 64 × 24 px, newest at the right edge; failed
/// probes leave a dashed baseline segment (F14).
class SparklineView extends StatelessWidget {
  const SparklineView({required this.sample, super.key});

  final LatencySample sample;
  static const size = Size(64, 24);
  static const ceiling = 400.0;

  @override
  Widget build(BuildContext context) {
    final latest =
        sample.milliseconds ?? sample.history.whereType<int>().lastOrNull ?? 0;
    final color = sample.unreachable
        ? FluentTheme.of(context).resources.systemFillColorCritical
        : bandColor(context, LatencyBand.of(latest));
    return CustomPaint(
      size: size,
      painter: _SparklinePainter(
        points: sample.history,
        color: color,
        gap: FluentTheme.of(context).resources.textFillColorTertiary,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.points,
    required this.color,
    required this.gap,
  });

  final List<int?> points;
  final Color color;
  final Color gap;

  @override
  void paint(Canvas canvas, Size size) {
    final slots = max(LatencyProbe.historyLength, 2);
    final step = size.width / (slots - 1);
    final offset = slots - points.length;
    final baseline = size.height - 2;
    Offset point(int index, int value) {
      final share =
          min(value.toDouble(), SparklineView.ceiling) / SparklineView.ceiling;
      return Offset(
        (index + offset) * step,
        baseline - share * (size.height - 4),
      );
    }

    final line = Path();
    var open = false;
    final gapPaint = Paint()
      ..color = gap.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var index = 0; index < points.length; index++) {
      final value = points[index];
      if (value != null) {
        final p = point(index, value);
        if (open) {
          line.lineTo(p.dx, p.dy);
        } else {
          line.moveTo(p.dx, p.dy);
        }
        open = true;
      } else {
        open = false;
        final x = (index + offset) * step;
        final end = min(x + step, size.width);
        // A dashed segment: two-pixel dashes along the baseline.
        for (var dash = x; dash < end; dash += 4) {
          canvas.drawLine(
            Offset(dash, baseline),
            Offset(min(dash + 2, end), baseline),
            gapPaint,
          );
        }
      }
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final last = points.lastOrNull;
    if (last != null) {
      canvas.drawCircle(
        point(points.length - 1, last),
        1.6,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.points != points || old.color != color;
}

/// One member line under a group card or in the expanded group (F16): dot,
/// name, the `✓ in use` / `skipped — …` note, latency right-aligned.
class GroupMemberRowView extends StatelessWidget {
  const GroupMemberRowView({
    required this.row,
    this.showsLatency = true,
    super.key,
  });

  final GroupMemberRow row;
  final bool showsLatency;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Row(
      children: [
        StatusGlyphView(glyph: row.glyph, size: 8),
        const SizedBox(width: 6),
        Text(row.tunnel.name, style: theme.typography.caption),
        if (row.note.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              row.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.caption?.copyWith(
                color: row.isActive
                    ? theme.accentColor
                    : theme.resources.textFillColorSecondary,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (showsLatency) LatencyLabel(sample: row.latency, fontSize: 11),
      ],
    );
  }
}
