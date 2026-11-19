import 'package:flutter/widgets.dart';

import 'consent_iq.dart';
import 'web_view.dart';

/// Exposes a [ConsentIQ] to the widget tree. Widgets that call [of] rebuild
/// whenever the consent state changes.
///
/// It also hosts the hidden web view that runs the captcha check when the
/// property requires one, so keep it mounted above the app.
class ConsentIQProvider extends InheritedNotifier<ConsentIQ> {
  const ConsentIQProvider({
    super.key,
    required ConsentIQ consentIQ,
    required super.child,
  }) : super(notifier: consentIQ);

  // Wrapping here rather than in the initializer keeps the constructor const.
  @override
  Widget get child => HiddenWebViewHost(child: super.child);

  static ConsentIQ of(BuildContext context) {
    final consentIQ = maybeOf(context);
    assert(consentIQ != null, 'No ConsentIQProvider found above this widget.');
    return consentIQ!;
  }

  static ConsentIQ? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConsentIQProvider>()?.notifier;
}
