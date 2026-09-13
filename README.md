# ConsentIQ Flutter SDK

The Flutter SDK for [ConsentIQ](https://consent.iqworks.ai), the consent management platform from IQWorks. It loads a property's configuration, shows a consent sheet on first launch, records the visitor's choices against a pseudonymous subject id, and lets the app gate features on consent.

Supports iOS and Android. Requires Flutter 3.24 or later and Dart 3.5 or later.

## Install

```sh
flutter pub add consentiq
```

## Quick start

Create one `ConsentIQ` for the app, call `init()` once, and put a `ConsentIQProvider` above `MaterialApp`. Mount a `ConsentSheet` anywhere below the app's `Navigator`, for example around the home screen.

```dart
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
    ),
  );
  consentIQ.init();
  runApp(ConsentIQProvider(consentIQ: consentIQ, child: const MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: ConsentSheet(child: HomeScreen()));
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final consentIQ = ConsentIQProvider.of(context);
    return Scaffold(
      body: Column(
        children: [
          ConsentGate(
            category: 'analytics',
            child: const Text('Analytics is on'),
          ),
          TextButton(
            onPressed: consentIQ.showSheet,
            child: const Text('Cookie preferences'),
          ),
        ],
      ),
    );
  }
}
```

On first launch the sheet appears automatically. Once the visitor has answered, the choice is stored on the ConsentIQ server and cached on the device, and the sheet stays hidden on later launches until the consent expires or `showSheet()` is called.

`init()` never throws. If the network is unavailable the app keeps running with every optional category off, and one line prefixed `[ConsentIQ]` is logged.

## Two keys per app

A ConsentIQ property is one platform. Create one property for iOS and one for Android in the dashboard, and pick the key by operating system at runtime as shown above. Keep the keys in your app configuration.

## API summary

### Configuration

Pass a `ConsentIQConfig` to `ConsentIQ`.

| Field | Default | Purpose |
| --- | --- | --- |
| `propertyKey` | required | The property's public key from the dashboard. |
| `apiUrl` | `https://consent.iqworks.ai` | Override when the property lives on another ConsentIQ deployment, such as a test environment. |
| `subjectId` | null | Use your own subject id instead of a generated one. |
| `autoGenerateSubjectId` | `true` | Generate and persist a UUID when no `subjectId` is given. |
| `language` | property default | Language for the sheet, for example `en` or `ar`. |
| `autoShow` | `true` | Show the sheet on init when no consent is recorded. |
| `debug` | `false` | Verbose logging prefixed `[ConsentIQ]`. |

### State and operations

`ConsentIQ` extends `ChangeNotifier`. Widgets read it with `ConsentIQProvider.of(context)`, which rebuilds the caller on every change, and other code can listen to it directly.

State:

- `consent`: `Map<String, bool>` of cookie categories. `necessary` is always true.
- `marketingConsent`: `Map<String, bool>` of marketing channels.
- `config`: the loaded `PropertyConfig`, or null before init completes.
- `isLoading`, `isSheetVisible`, `language`, `regulation`, `subjectId`.

Operations:

- `init()`: load the config and any recorded consent. Runs once.
- `hasConsent(category)`, `hasMarketingConsent(channel)`.
- `acceptAll()`: every enabled category on.
- `rejectAll()`: only `necessary` on.
- `updateConsent({...})`, `updateMarketingConsent({...})`: merge a partial update.
- `savePreferences(fullMap)`: what the sheet's Save button calls.
- `showSheet()`, `hideSheet()`, `dismissSheet()`.
- `resetConsent()`: clear the local cache and subject id and return to defaults.

Every write updates local state first, then posts to ConsentIQ, then caches the result and calls `onConsentChange`. A failed post is logged and the local state is kept.

### Widgets

- `ConsentIQProvider(consentIQ:, child:)`: an `InheritedNotifier` that exposes the `ConsentIQ`.
- `ConsentSheet({child})`: presents the consent sheet as a modal bottom sheet whenever `isSheetVisible` is true. Must sit below a `Navigator`. Renders `child` in place.
- `ConsentGate(category:, child:, placeholder:)`: renders `child` only while `hasConsent(category)` is true, otherwise `placeholder`.

The sheet renders the property's title, description and button labels in the active language, links to the cookie notice, and lists each category with a switch. Languages such as Arabic lay out right-to-left.

### Marketing form consent

`FormConsent` records marketing consent collected on your own form, with the form consent method, against a subject your app identifies.

```dart
final form = FormConsent(
  propertyKey: 'YOUR_IOS_PROPERTY_KEY',
  subjectId: 'user-42',
);
form.setChannel('email', true);
final result = await form.submit();
```

Channels default to `email`, `sms`, `whatsapp` and `push`. `toggleChannel`, `setChannel`, `submit()` and `reset()` are available; `submit()` returns null on failure.

### API client

`ConsentIQApiClient` is the HTTP client behind the SDK, exposed for apps that need direct access to `getConfig()`, `getConsent(subjectId)`, `submitConsent(...)` and `verifyConsent(consentId)`. Tests can pass their own `http.Client` to stub it.

## Callbacks

All callbacks on `ConsentIQConfig` are optional.

| Callback | Fires when |
| --- | --- |
| `onConsentChange(consent, marketing)` | A write was recorded on the server. |
| `onOpen()` | The sheet is shown, on init or through `showSheet()`. |
| `onAccept(event)` | The visitor tapped Accept all. `event.scope` is `ConsentScope.all`. |
| `onReject(event)` | The visitor tapped Reject all. |
| `onSave(event)` | The visitor saved a custom selection. |
| `onClose()` | The visitor backed out with the back button, a swipe or a tap outside the sheet. Never fires on accept, reject, save or `hideSheet()`. |

## Limitations

**Captcha.** ConsentIQ can require a Cloudflare Turnstile check on every consent submission for a property. Turnstile has no native mobile SDK, so a property with "Require captcha" turned on refuses every submission from this SDK with HTTP 400. The SDK logs a warning at init when it detects this. Turn off "Require captcha" for your iOS and Android properties in the ConsentIQ dashboard.

## License

MIT. See [LICENSE](LICENSE).
