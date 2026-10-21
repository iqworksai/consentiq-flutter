## Unreleased

- IAB TCF in-app support. When a property has TCF on and GDPR applies to the visitor, the SDK shows ConsentIQ's hosted TCF page full screen in place of the consent sheet, and writes the `IABTCF_*` keys where IAB vendors' SDKs read them: Android's default SharedPreferences and iOS `UserDefaults.standard`. The page records the consent itself; its category choices update `consent` and fire `onAccept`, `onReject` or `onSave`, as the visitor chose, and `onConsentChange`.
- The SDK removes the `IABTCF_*` keys it wrote when consent is reset or expires, and all of them when the property no longer runs TCF. Keys written by another CMP are never touched.
- `showSheet()` opens the TCF page when TCF is active, and `showTcfPreferences()` opens it explicitly. New state: `isTcfActive`, `isTcfVisible`.
- New `onError` callback on `ConsentIQConfig`, for failures the SDK recovers from. If the TCF page fails, it reports there and the consent sheet is shown instead.
- The package is now a Flutter plugin, with a small Android and iOS part that writes the TCF keys, since `shared_preferences` cannot write them in the form vendors read. Rebuild the app after upgrading; there is nothing to configure.
- The hidden captcha web view now accepts messages only from the hosted captcha page.

## 1.1.0

- Properties with "Require CAPTCHA" on now accept submissions from this SDK. Before each submission the SDK runs Cloudflare Turnstile invisibly in a hidden web view that `ConsentIQProvider` hosts, and sends the token with the consent. If the check fails or needs the visitor to solve a challenge, nothing is sent and a warning is logged.
- `FormConsent` loads the property config on its first submission, to learn whether a CAPTCHA is required.
- `ConsentIQ` and `FormConsent` take an optional `captchaTokenSource`, and `ConsentIQApiClient.submitConsent` an optional `captchaToken`.
- New dependency: `webview_flutter`. It needs no newer Android or iOS version than the SDK's other plugins.
- `captchaWarning` is deprecated and no longer logged.

## 1.0.1

- Warnings no longer print raw error text. They print in release builds too, and a network error's text carries the request URL, which ends in the subject id.
- Debug logs no longer include the subject id or the consent id.
- The example app turns on debug logging in debug builds only.
- README: a caller-supplied `subjectId` must be random and unguessable.

## 1.0.0

Initial release.

- `ConsentIQ` state machine on `ChangeNotifier`: config load, consent restore from the server or the local cache, expiry handling, accept, reject, save, update and reset.
- `ConsentSheet` modal bottom sheet with server-provided labels, category switches, cookie notice link and right-to-left layout.
- `ConsentIQProvider` and `ConsentGate` widgets.
- `FormConsent` for marketing consent collected on the app's own forms.
- `ConsentIQApiClient` and `ConsentStorage`, both injectable for tests.
