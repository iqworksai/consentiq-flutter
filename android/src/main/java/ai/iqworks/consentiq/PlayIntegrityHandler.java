package ai.iqworks.consentiq;

import android.content.Context;
import android.util.Base64;

import androidx.annotation.NonNull;

import com.google.android.play.core.integrity.IntegrityManagerFactory;
import com.google.android.play.core.integrity.IntegrityTokenRequest;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/**
 * Play Integrity for the Dart SDK, from a classic request: only a classic token can be decrypted
 * with the response keys the customer downloads from Play Console. The nonce, base64url of the
 * body's SHA-256, is computed here from the exact body Dart sends.
 */
final class PlayIntegrityHandler implements MethodChannel.MethodCallHandler {
  static final String CHANNEL = "ai.iqworks.consentiq/attest";

  private final Context context;

  PlayIntegrityHandler(Context context) {
    this.context = context;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if (!"playIntegrityToken".equals(call.method)) {
      result.notImplemented();
      return;
    }
    Number project = call.argument("cloudProjectNumber");
    String body = call.argument("body");
    if (body == null) {
      result.error("bad_arguments", null, null);
      return;
    }
    String nonce;
    try {
      nonce = nonce(body);
    } catch (NoSuchAlgorithmException e) {
      result.error("play_integrity", e.getMessage(), null);
      return;
    }
    IntegrityTokenRequest.Builder request = IntegrityTokenRequest.builder().setNonce(nonce);
    if (project != null) request.setCloudProjectNumber(project.longValue());
    IntegrityManagerFactory.create(context)
        .requestIntegrityToken(request.build())
        .addOnSuccessListener(token -> result.success(token.token()))
        .addOnFailureListener(e -> result.error("play_integrity", e.getMessage(), null))
        // A cancelled task calls neither listener above; answer it so the Dart call returns.
        .addOnCanceledListener(() -> result.error("play_integrity", "cancelled", null));
  }

  static String nonce(String body) throws NoSuchAlgorithmException {
    byte[] digest =
        MessageDigest.getInstance("SHA-256").digest(body.getBytes(StandardCharsets.UTF_8));
    return Base64.encodeToString(digest, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
  }
}
