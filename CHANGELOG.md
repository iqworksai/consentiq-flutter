## Unreleased

- A decision ConsentIQ has not recorded is kept for a later resend on no answer, a `5xx`, `429` or an unanswered challenge, not only on `429`, and a newer decision replaces it. A `400`, `403`, `404`, `409` or `422`, or any failure on a property that requires a captcha on every submit, drops it with its local cache, fires `onError` (`consent`, `refused`), and the next launch asks again with nothing granted. A kept decision carries the notice version it was made under and is dropped when the notice or the categories change.
- The local cache is written before the post and belongs to its subject id; a different subject id shows the sheet again.
- `identityToken` is sent only with a subject id you supply. `FormConsent` takes `identityFor` and sends the signed identifier when the subject is that identifier written differently.
- A restore refused with `403` drops the local cache, fires `onError` and shows the sheet.
- `FormConsent` no longer throws for a subject id containing `:`; `submit()` logs it and returns `null`, as on iOS and Android.
- The in-app TCF page receives the `identityToken` for a subject id you supply.
- A TCF decision the in-app page reports as not recorded (`recorded: false`) still applies for the session, but its stored TC record and local cache are dropped, `onError` fires (`consent`, `refused`, with the status when there was one) in place of `onConsentChange`, and the next launch asks again. It is not kept for a resend, which could not carry its TC string.

- A subject id you supply (`ConsentIQConfig.subjectId`, `FormConsent`) is sent with `subjectSource: "site"` on every write, and to the in-app TCF page, so ConsentIQ stores it apart from the ids the SDK generates. A supplied id containing `:` is refused: `init()` reports a `ConsentIQError` (`config`, `invalid-subject-id`) through `onError` and keeps consent local, and `FormConsent.submit()` returns `null`. Its stored consent is restored with `POST /api/public/consent/{key}/{subjectId}` and the `identityToken`, which reads only records ConsentIQ verified; without a token the SDK does not look it up and relies on the copy on the device. Generated ids are still restored with the open lookup.
- When ConsentIQ answers a submission with `428 captcha_required`, which it can do on any property when a submission looks automated, the SDK solves one Cloudflare Turnstile challenge and submits once more. `FormConsent.submit()` does the same.
- The captcha page is loaded with the property key, so a token is accepted only for that property.
- A challenge stays hidden unless Cloudflare asks for interaction; then it is shown over the app with a close button. Once shown it waits up to 2 minutes. Closing it, a failure or a timeout sends nothing more, keeps the local choice and logs the usual captcha warning.
- App attestation. On iOS, once per install and property the SDK generates an App Attest key, registers it with ConsentIQ, and sends `X-ConsentIQ-Attest-Key` and `X-ConsentIQ-Assertion`, an assertion over the exact request body, with every submission. On Android, each submission sends `X-ConsentIQ-Integrity`, a Play Integrity token from a classic request whose nonce is the body's SHA-256, verified with the response keys you download from Play Console. The new `ConsentIQConfig.playIntegrityCloudProjectNumber` (and `FormConsent(playIntegrityCloudProjectNumber:)`) is only needed for an app also distributed outside Google Play. Where either cannot run, nothing is sent and ConsentIQ asks for a captcha instead. The plugin's Android code depends on `com.google.android.play:integrity`, and its iOS code weak-links DeviceCheck.
- A submission ConsentIQ answers with `429` is kept and sent once more on the next launch, without a captcha; it is dropped once recorded, after three attempts, or after seven days. A `400`, `404`, `409` or `422` answer drops it. A `403` (an identity token that did not verify, or one the property requires) fires `onError` with source `consent` and code `refused`, and is not retried. `ConsentIQError` has a new optional `message`. A kept decision is resent only for the same subject id, property and API URL; a newer decision replaces it; a newer record on ConsentIQ wins over it; and a `429` that arrives after `resetConsent()` is ignored.
- App Attest keys are kept per API URL and property. A property without app identifiers (`409`) is retried after three days, and a key challenged on three attested submissions in a row is registered again. Attestation and Play Integrity calls give up after 10 seconds, and a cancelled Play Integrity task is answered, so a submission falls back to the captcha instead of waiting.
- `ConsentIQConfig.identityToken` and `FormConsent(identityToken:)` send your server's signature for the person with each submission, unread by the SDK.
- `ConsentSheet` uses the banner's background and text colors from the dashboard when the server sends them (new optional `BannerConfig.bannerBgColor` and `bannerTextColor`), with secondary text matched to a light or dark background. Without them, it follows the app's theme.
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
