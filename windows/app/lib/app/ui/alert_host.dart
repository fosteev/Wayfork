import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/app_scope.dart';

/// Renders `AppModel.alerts` — the macOS `NSAlert` calls, which the model
/// turned into state — as a Fluent dialog, oldest first. Drawn inline instead
/// of pushed with `showDialog` so the queue stays a pure function of the
/// model and survives a rebuild.
class AlertHost extends StatelessWidget {
  const AlertHost({required this.child, required this.onAction, super.key});

  final Widget child;

  /// Runs the alert's second button; the alert is dismissed either way.
  final void Function(AppAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final alert = model.alerts.isEmpty ? null : model.alerts.first;
    return Stack(
      children: [
        child,
        if (alert != null) ...[
          // Blocks the page underneath, the way a real modal would.
          const ModalBarrier(dismissible: false, color: Color(0x99000000)),
          Center(
            child: ContentDialog(
              title: Text(alert.title),
              content: Text(alert.message),
              actions: [
                Button(
                  onPressed: () => model.dismissAlert(alert),
                  child: const Text('Close'),
                ),
                if (alert.action case final action?)
                  FilledButton(
                    onPressed: () {
                      model.dismissAlert(alert);
                      onAction(action);
                    },
                    child: Text(action.title),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
