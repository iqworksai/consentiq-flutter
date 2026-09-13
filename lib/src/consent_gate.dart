import 'package:flutter/widgets.dart';

import 'provider.dart';

/// Renders [child] only while the visitor has consented to [category].
/// Otherwise, and while consent is still loading, renders [placeholder].
class ConsentGate extends StatelessWidget {
  const ConsentGate({
    super.key,
    required this.category,
    required this.child,
    this.placeholder,
  });

  final String category;
  final Widget child;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final consentIQ = ConsentIQProvider.of(context);
    if (consentIQ.hasConsent(category)) return child;
    return placeholder ?? const SizedBox.shrink();
  }
}
