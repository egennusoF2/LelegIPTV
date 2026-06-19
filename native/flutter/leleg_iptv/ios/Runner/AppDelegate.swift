import Flutter
import ObjectiveC.runtime
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentInteractionControllerDelegate {
  private var documentInteractionController: UIDocumentInteractionController?
  private var storageChannel: FlutterMethodChannel?
  private var downloadDelegates: [Int: LelegDownloadDelegate] = [:]
  private var downloadSessions: [Int: URLSession] = [:]
  private var backgroundSessionCompletionHandlers: [String: () -> Void] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    disableTouchRateCorrectionVSyncCrashOnIOS26()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerStorageChannel(with: engineBridge.pluginRegistry)
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    backgroundSessionCompletionHandlers[identifier] = completionHandler
  }

  private func disableTouchRateCorrectionVSyncCrashOnIOS26() {
    guard #available(iOS 26.0, *) else { return }
    let selector = NSSelectorFromString("createTouchRateCorrectionVSyncClientIfNeeded")
    guard
      let method = class_getInstanceMethod(FlutterViewController.self, selector)
    else {
      return
    }

    let block: @convention(block) (AnyObject) -> Void = { _ in }
    method_setImplementation(method, imp_implementationWithBlock(block as Any))
  }

  private func registerStorageChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "LelegStoragePlugin") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.lelegiptv.native/storage",
      binaryMessenger: registrar.messenger()
    )
    storageChannel = channel
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "downloadsDirectory":
        do {
          result(try self.downloadsDirectory().path)
        } catch {
          result(FlutterError(code: "directory_failed", message: error.localizedDescription, details: nil))
        }
      case "notifyFileSaved":
        result(true)
      case "downloadFile":
        guard
          let args = call.arguments as? [String: Any],
          let url = args["url"] as? String,
          let filename = args["filename"] as? String,
          !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          result(FlutterError(code: "invalid_arguments", message: "Missing download URL or filename", details: nil))
          return
        }
        self.downloadFile(
          urlString: url,
          filename: filename,
          referer: args["referer"] as? String,
          userAgent: args["userAgent"] as? String,
          movieId: args["movieId"] as? Int
        ) { path, error in
          DispatchQueue.main.async {
            if let error {
              result(FlutterError(code: "download_failed", message: error.localizedDescription, details: nil))
              return
            }
            result(path)
          }
        }
      case "openFile":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          result(false)
          return
        }
        result(self.openFile(path: path))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func downloadsDirectory() throws -> URL {
    let documents = try FileManager.default.url(
      for: .documentDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = documents.appendingPathComponent("LelegIPTV", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func downloadFile(
    urlString: String,
    filename: String,
    referer: String?,
    userAgent: String?,
    movieId: Int?,
    completion: @escaping (String?, Error?) -> Void
  ) {
    guard let url = URL(string: urlString) else {
      completion(nil, NSError(domain: "LelegDownload", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "URL download non valido"
      ]))
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    if let referer, !referer.isEmpty {
      request.setValue(referer, forHTTPHeaderField: "Referer")
    }
    if let userAgent, !userAgent.isEmpty {
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    do {
      let directory = try downloadsDirectory()
      let safeFilename = filename.replacingOccurrences(of: "/", with: " ")
      let destination = directory.appendingPathComponent(safeFilename)
      let delegate = LelegDownloadDelegate(
        sessionIdentifier: "com.lelegiptv.download.\(movieId ?? Int(Date().timeIntervalSince1970)).\(UUID().uuidString)",
        destination: destination,
        movieId: movieId,
        progress: { [weak self] movieId, progress in
          guard let movieId else { return }
          DispatchQueue.main.async {
            self?.storageChannel?.invokeMethod("downloadProgress", arguments: [
              "movieId": movieId,
              "progress": progress
            ])
          }
        },
        completion: { [weak self] taskIdentifier, path, error in
          DispatchQueue.main.async {
            self?.downloadDelegates.removeValue(forKey: taskIdentifier)
            self?.downloadSessions.removeValue(forKey: taskIdentifier)
            completion(path, error)
          }
        },
        finishEvents: { [weak self] identifier in
          DispatchQueue.main.async {
            self?.backgroundSessionCompletionHandlers.removeValue(forKey: identifier)?()
          }
        }
      )
      let configuration = URLSessionConfiguration.background(withIdentifier: delegate.sessionIdentifier)
      configuration.sessionSendsLaunchEvents = true
      configuration.isDiscretionary = false
      configuration.allowsCellularAccess = true
      configuration.allowsExpensiveNetworkAccess = true
      configuration.allowsConstrainedNetworkAccess = true
      configuration.httpMaximumConnectionsPerHost = 4
      configuration.networkServiceType = .responsiveData
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 60 * 60 * 2
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      let task = session.downloadTask(with: request)
      delegate.taskIdentifier = task.taskIdentifier
      downloadDelegates[task.taskIdentifier] = delegate
      downloadSessions[task.taskIdentifier] = session
      task.resume()
    } catch {
      completion(nil, error)
    }
  }

  private func openFile(path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    documentInteractionController = UIDocumentInteractionController(url: url)
    documentInteractionController?.delegate = self
    if let controller = topViewController() {
      return documentInteractionController?.presentPreview(animated: true) ?? false
    }
    return false
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    return topViewController() ?? UIViewController()
  }

  private func topViewController() -> UIViewController? {
    var controller = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController

    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

private final class LelegDownloadDelegate: NSObject, URLSessionDownloadDelegate {
  var taskIdentifier: Int = -1
  let sessionIdentifier: String

  private let destination: URL
  private let movieId: Int?
  private let progress: (Int?, Double) -> Void
  private let completion: (Int, String?, Error?) -> Void
  private let finishEvents: (String) -> Void
  private var completed = false

  init(
    sessionIdentifier: String,
    destination: URL,
    movieId: Int?,
    progress: @escaping (Int?, Double) -> Void,
    completion: @escaping (Int, String?, Error?) -> Void,
    finishEvents: @escaping (String) -> Void
  ) {
    self.sessionIdentifier = sessionIdentifier
    self.destination = destination
    self.movieId = movieId
    self.progress = progress
    self.completion = completion
    self.finishEvents = finishEvents
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else {
      progress(movieId, 0)
      return
    }
    progress(movieId, min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    if let response = downloadTask.response as? HTTPURLResponse,
       response.statusCode < 200 || response.statusCode >= 300 {
      completed = true
      completion(downloadTask.taskIdentifier, nil, NSError(domain: "LelegDownload", code: response.statusCode, userInfo: [
        NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"
      ]))
      session.invalidateAndCancel()
      return
    }

    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: location, to: destination)
      completed = true
      progress(movieId, 1)
      completion(downloadTask.taskIdentifier, destination.path, nil)
      session.finishTasksAndInvalidate()
    } catch {
      completed = true
      completion(downloadTask.taskIdentifier, nil, error)
      session.invalidateAndCancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard !completed else { return }
    completed = true
    completion(task.taskIdentifier, nil, error ?? NSError(domain: "LelegDownload", code: -3, userInfo: [
      NSLocalizedDescriptionKey: "Download interrotto"
    ]))
    session.invalidateAndCancel()
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    finishEvents(sessionIdentifier)
  }
}
