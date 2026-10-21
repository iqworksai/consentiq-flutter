import Flutter
import Foundation

/// Writes the IABTCF_* keys to `UserDefaults.standard`, where IAB vendors read.
public final class ConsentIQPlugin: NSObject, FlutterPlugin {
  private static let channelName = "ai.iqworks.consentiq/iabtcf"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ConsentIQPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "update" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let arguments = call.arguments as? [String: Any] ?? [:]
    for key in arguments["remove"] as? [String] ?? [] {
      defaults.removeObject(forKey: key)
    }
    for (key, value) in arguments["ints"] as? [String: Any] ?? [:] {
      if let number = value as? NSNumber {
        defaults.set(number.intValue, forKey: key)
      }
    }
    for (key, value) in arguments["strings"] as? [String: Any] ?? [:] {
      if let string = value as? String {
        defaults.set(string, forKey: key)
      }
    }
    result(nil)
  }
}
