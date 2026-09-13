import 'dart:io' show Platform;

import 'package:consentiq/consentiq.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final consentIQ = ConsentIQ(
    ConsentIQConfig(
      propertyKey: Platform.isIOS
          ? 'YOUR_IOS_PROPERTY_KEY'
          : 'YOUR_ANDROID_PROPERTY_KEY',
      debug: true,
      onConsentChange: (consent, marketing) =>
          debugPrint('consent changed: $consent'),
      onAccept: (event) => debugPrint('accepted ${event.scope.name}'),
      onReject: (_) => debugPrint('rejected'),
      onSave: (_) => debugPrint('saved'),
      onOpen: () => debugPrint('sheet opened'),
      onClose: () => debugPrint('sheet dismissed'),
    ),
  );
  consentIQ.init();
  runApp(ConsentIQProvider(consentIQ: consentIQ, child: const ExampleApp()));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ConsentIQ example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFF97316)),
      home: const ConsentSheet(child: HomeScreen()),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final consentIQ = ConsentIQProvider.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('ConsentIQ example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (consentIQ.isLoading)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Loading consent'),
            )
          else ...[
            ListTile(
              title: const Text('Regulation'),
              trailing: Text(consentIQ.regulation ?? 'none'),
            ),
            ListTile(
              title: const Text('Language'),
              trailing: Text(consentIQ.language),
            ),
          ],
          const Divider(),
          for (final entry in consentIQ.consent.entries)
            ListTile(
              title: Text(entry.key),
              trailing: Icon(
                entry.value ? Icons.check_circle : Icons.cancel_outlined,
                color: entry.value ? Colors.green : Colors.grey,
              ),
            ),
          const Divider(),
          ConsentGate(
            category: 'analytics',
            placeholder: const ListTile(
              leading: Icon(Icons.visibility_off_outlined),
              title: Text('Analytics is off'),
              subtitle: Text('Allow analytics in preferences to enable it.'),
            ),
            child: const ListTile(
              leading: Icon(Icons.insights),
              title: Text('Analytics is on'),
              subtitle: Text('This section renders only with consent.'),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: consentIQ.showSheet,
            child: const Text('Preferences'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: consentIQ.resetConsent,
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}
