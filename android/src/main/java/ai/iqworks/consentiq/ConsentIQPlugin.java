package ai.iqworks.consentiq;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.util.List;
import java.util.Map;

/** Writes the IABTCF_* keys to the app's default SharedPreferences. */
public final class ConsentIQPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private static final String CHANNEL = "ai.iqworks.consentiq/iabtcf";

  private MethodChannel channel;
  private SharedPreferences preferences;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    Context context = binding.getApplicationContext();
    // The file PreferenceManager.getDefaultSharedPreferences opens, where IAB vendors read.
    preferences =
        context.getSharedPreferences(context.getPackageName() + "_preferences", Context.MODE_PRIVATE);
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
    preferences = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if (!"update".equals(call.method)) {
      result.notImplemented();
      return;
    }
    SharedPreferences.Editor editor = preferences.edit();
    Object remove = call.argument("remove");
    if (remove instanceof List) {
      for (Object key : (List<?>) remove) {
        if (key instanceof String) editor.remove((String) key);
      }
    }
    Object ints = call.argument("ints");
    if (ints instanceof Map) {
      for (Map.Entry<?, ?> entry : ((Map<?, ?>) ints).entrySet()) {
        if (entry.getKey() instanceof String && entry.getValue() instanceof Number) {
          editor.putInt((String) entry.getKey(), ((Number) entry.getValue()).intValue());
        }
      }
    }
    Object strings = call.argument("strings");
    if (strings instanceof Map) {
      for (Map.Entry<?, ?> entry : ((Map<?, ?>) strings).entrySet()) {
        if (entry.getKey() instanceof String && entry.getValue() instanceof String) {
          editor.putString((String) entry.getKey(), (String) entry.getValue());
        }
      }
    }
    editor.apply();
    result.success(null);
  }
}
