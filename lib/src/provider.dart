import 'package:flutter/widgets.dart';

import 'consent_iq.dart';

/// Exposes a [ConsentIQ] to the widget tree. Widgets that call [of] rebuild
/// whenever the consent state changes.
class ConsentIQProvider extends InheritedNotifier<ConsentIQ> {
  const ConsentIQProvider({
    super.key,
    required ConsentIQ consentIQ,
    required super.child,
  }) : super(notifier: consentIQ);

  static ConsentIQ of(BuildContext context) {
    final consentIQ = maybeOf(context);
    assert(consentIQ != null, 'No ConsentIQProvider found above this widget.');
    return consentIQ!;
  }

  static ConsentIQ? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConsentIQProvider>()?.notifier;
}
