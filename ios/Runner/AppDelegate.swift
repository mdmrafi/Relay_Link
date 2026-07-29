import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    installSmsStub(binaryMessenger: engineBridge.binaryMessenger)
  }

  /// Installs a stub MethodChannel for SMS operations. Apple disallows
  /// programmatic SMS send/receive from third-party apps, so we surface a
  /// PlatformException that mirrors the Dart-side guard.
  private func installSmsStub(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "relaylink/sms",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "sendSms", "requestSmsPermissions":
        result(FlutterError(
          code: "unavailable",
          message: "SMS unavailable on iOS",
          details: nil
        ))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}