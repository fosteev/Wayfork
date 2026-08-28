import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/ui/app_scope.dart';

/// The service-missing / version-mismatch strip of the prototype
/// (docs/design/prototype/windows.html, board 8): shown on every page while
/// the app cannot talk to the service, with the "repair installation" hint of
/// the error catalogue.
class ServiceBanner extends StatelessWidget {
  const ServiceBanner({required this.onRepair, super.key});

  final VoidCallback onRepair;

  @override
  Widget build(BuildContext context) {
    final issue = AppScope.of(context).serviceIssue;
    if (issue == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: InfoBar(
        title: Text(issue.message),
        content: Text(issue.hint),
        severity: issue.needsRepair
            ? InfoBarSeverity.error
            : InfoBarSeverity.warning,
        isLong: false,
        action: issue.needsRepair
            ? Button(
                onPressed: onRepair,
                child: const Text('Repair Installation'),
              )
            : null,
      ),
    );
  }
}
