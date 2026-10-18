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
