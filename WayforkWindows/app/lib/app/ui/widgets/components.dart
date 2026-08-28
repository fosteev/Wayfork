import 'dart:math';

import 'package:fluent_ui/fluent_ui.dart';
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
  });

  final StatusGlyph glyph;
  final Color up;
  final Color idle;
  final Color transitioning;
  final Color failed;
  final Color cross;

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
    }
  }

  Paint _stroke(Color color) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.up != up || old.failed != failed;
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
