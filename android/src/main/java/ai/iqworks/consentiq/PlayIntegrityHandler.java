package ai.iqworks.consentiq;

import android.content.Context;
import android.util.Base64;

import androidx.annotation.NonNull;

import com.google.android.play.core.integrity.IntegrityManagerFactory;
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest;
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider;
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/**
 * Play Integrity for the Dart SDK. The request hash, base64url of the body's SHA-256, is computed
 * here from the exact body Dart sends.
 */
final class PlayIntegrityHandler implements MethodChannel.MethodCallHandler {
  static final String CHANNEL = "ai.iqworks.consentiq/attest";

  private final Context context;
  private StandardIntegrityTokenProvider provider;
  private long providerProject;

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
    if (project == null || body == null) {
      result.error("bad_arguments", null, null);
      return;
    }
    String requestHash;
    try {
      requestHash = requestHash(body);
    } catch (NoSuchAlgorithmException e) {
      result.error("play_integrity", e.getMessage(), null);
      return;
    }
    long projectNumber = project.longValue();
    if (provider != null && providerProject == projectNumber) {
      request(provider, requestHash, result);
      return;
    }
    IntegrityManagerFactory.createStandard(context)
        .prepareIntegrityToken(
            PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(projectNumber).build())
        .addOnSuccessListener(
            prepared -> {
              provider = prepared;
              providerProject = projectNumber;
              request(prepared, requestHash, result);
            })
        .addOnFailureListener(e -> result.error("play_integrity", e.getMessage(), null))
        // A cancelled task calls neither listener above; answer it so the Dart call returns.
        .addOnCanceledListener(() -> result.error("play_integrity", "cancelled", null));
  }

  private void request(
      StandardIntegrityTokenProvider current, String requestHash, MethodChannel.Result result) {
    current
        .request(StandardIntegrityTokenRequest.builder().setRequestHash(requestHash).build())
        .addOnSuccessListener(token -> result.success(token.token()))
        .addOnFailureListener(
            e -> {
              // A provider can expire; the next submission prepares a fresh one.
              if (provider == current) provider = null;
              result.error("play_integrity", e.getMessage(), null);
            })
        .addOnCanceledListener(() -> result.error("play_integrity", "cancelled", null));
  }

  static String requestHash(String body) throws NoSuchAlgorithmException {
    byte[] digest =
        MessageDigest.getInstance("SHA-256").digest(body.getBytes(StandardCharsets.UTF_8));
    return Base64.encodeToString(digest, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
  }
}
