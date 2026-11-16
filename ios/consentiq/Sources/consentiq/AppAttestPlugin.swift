import CommonCrypto
import DeviceCheck
import Flutter
import Foundation

/// App Attest for the Dart SDK. Each call hashes the client data here, so the bytes App Attest signs
/// are exactly the ones Dart sent.
final class AppAttestPlugin: NSObject {
  static let channelName = "ai.iqworks.consentiq/attest"

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 14.0, *) else {
      call.method == "appAttestSupported" ? result(false) : result(FlutterMethodNotImplemented)
      return
    }
    let service = DCAppAttestService.shared
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "appAttestSupported":
      result(service.isSupported)
    case "appAttestGenerateKey":
      service.generateKey { keyId, error in
        Self.finish(result, keyId, error)
      }
    case "appAttestKey", "appAttestAssertion":
      guard let keyId = arguments["keyId"] as? String,
        let clientData = arguments["clientData"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_arguments", message: nil, details: nil))
        return
      }
      let hash = Self.sha256(clientData.data)
      if call.method == "appAttestKey" {
        service.attestKey(keyId, clientDataHash: hash) { attestation, error in
          Self.finish(result, attestation.map(FlutterStandardTypedData.init(bytes:)), error)
        }
      } else {
        service.generateAssertion(keyId, clientDataHash: hash) { assertion, error in
          Self.finish(result, assertion.map(FlutterStandardTypedData.init(bytes:)), error)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // CommonCrypto rather than CryptoKit, which needs iOS 13 above this plugin's minimum.
  private static func sha256(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    return Data(digest)
  }

  private static func finish(_ result: @escaping FlutterResult, _ value: Any?, _ error: Error?) {
    DispatchQueue.main.async {
      if let error {
        result(FlutterError(code: "app_attest", message: error.localizedDescription, details: nil))
      } else {
        result(value)
      }
    }
  }
}
