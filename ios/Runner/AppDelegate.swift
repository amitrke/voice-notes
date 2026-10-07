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

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AudioConverter") {
      let channel = FlutterMethodChannel(
        name: "com.subnext.voicenotes/audio", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "toWav16kMono" else { return result(FlutterMethodNotImplemented) }
        guard let args = call.arguments as? [String: Any],
          let src = args["src"] as? String, let dest = args["dest"] as? String
        else { return result(FlutterError(code: "args", message: "src and dest are required", details: nil)) }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try AudioConverter.toWav16kMono(src: src, dest: dest)
            DispatchQueue.main.async { result(dest) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "convert", message: "\(error)", details: nil))
            }
          }
        }
      }
    }
  }
}
