import 'package:flutter/widgets.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/app_navigation.dart';

/// Hands the model to the widget tree and rebuilds its dependents on every
/// `notifyListeners` — the one place the UI reads state from.
class AppScope extends InheritedNotifier<AppModel> {
  const AppScope({required AppModel model, required super.child, super.key})
    : super(notifier: model);

  static AppModel of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'no AppScope above this widget');
    return scope!.notifier!;
  }
}

/// The same for the page the window shows.
class NavigationScope extends InheritedNotifier<AppNavigator> {
  const NavigationScope({
    required AppNavigator navigator,
    required super.child,
    super.key,
  }) : super(notifier: navigator);

  static AppNavigator of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<NavigationScope>();
    assert(scope != null, 'no NavigationScope above this widget');
    return scope!.notifier!;
  }
}
