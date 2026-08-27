import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/main.dart';

void main() {
  testWidgets('the shell shows the five navigation pages', (tester) async {
    await tester.pumpWidget(const WayforkApp());
    await tester.pumpAndSettle();
    for (final title in ['Dashboard', 'Tunnels', 'Rules', 'General', 'Logs']) {
      expect(find.textContaining(title), findsWidgets, reason: title);
    }
  });
}
