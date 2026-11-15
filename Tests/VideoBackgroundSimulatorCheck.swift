// Compiles only into a temporary iOS Simulator app. The player and navigation
// surface helper are the unchanged production sources, copied by the runner.
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import CoreVideo

enum AppTheme {
    static let gamingBackground = Color(red: 0.090, green: 0.094, blue: 0.098)
}

@MainActor
final class VideoScenario: ObservableObject {
    @Published var resource: AppBackgroundVideo = .login
    @Published var showNavigation = false
    @Published var clearNavigation = false
    @Published var selectedTab = 0
}

struct VideoCheckRoot: View {
    @ObservedObject var scenario: VideoScenario

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppVideoBackdrop(video: scenario.resource)
                if scenario.showNavigation {
                    // A test-only marker occupies the SAME underlying plane as
                    // video. A settled opaque navigation surface hides it.
                    Color(red: 0.95, green: 0.08, blue: 0.65)
                        .frame(width: 60, height: 60)
                        .position(x: geometry.size.width * 0.25,
                                  y: geometry.size.height * 0.68)
                    ZStack {
                        ForEach(0..<3) { tab in
                            NavigationStack {
                                ScrollView {
                                    VStack {
                                        Text("Video check tab \(tab)")
                                            .foregroundStyle(.white)
                                            .padding(12)
                                            .background(Color(white: 0.14))
                                        Color.clear.frame(height: 1200)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .appVideoNavigationSurface()
                                .navigationTitle("Tab \(tab)")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbarBackground(Color(white: 0.10), for: .navigationBar)
                                .toolbarBackground(.visible, for: .navigationBar)
                            }
                            .opacity(tab == scenario.selectedTab ? 1 : 0)
                            .allowsHitTesting(tab == scenario.selectedTab)
                        }
                    }
                    .environment(\.hasAppVideoBackground, scenario.clearNavigation)
                    .id(scenario.clearNavigation)
                }
            }
        }
        .environment(\.scenePhase, .active)
        .environment(\.hasAppVideoBackground, true)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

enum CheckFailure: Error { case failed(String) }

@MainActor
final class VideoDriver {
    let scenario = VideoScenario()
    weak var window: UIWindow?
    private var timer: Timer?
    private var playerIDs = Set<ObjectIdentifier>()
    private var observedItem: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var previousTime: [String: Double] = [:]
    private var wraps: [String: Int] = [:]
    private var frames: [String: Int] = [:]
    private var samples: [[String: Any]] = []
    private var failures: [String] = []
    private var captures: [String] = []
    private var pendingCapture: String?
    private var result = "RUNNING"
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func start(in window: UIWindow) {
        self.window = window
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        Task { @MainActor in
            do {
                try await run()
                result = "PASS"
            } catch {
                failures.append(String(describing: error))
                result = "FAIL"
            }
            writeReport()
            timer?.invalidate()
            timer = nil
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure.failed(message) }
    }

    private func wait(_ message: String, seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try require(Date() < deadline, "Timed out: " + message)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func capture(_ name: String) async throws {
        if name != "main-baseline" {
            try await wait("video surface ready at " + name, seconds: 5) {
                guard let window, let layer = layers(in: window.layer).first,
                      layer.isReadyForDisplay && !layer.isHidden else { return false }
                if let owner = layer.superlayer?.delegate as? UIView {
                    let posters = owner.subviews.compactMap { $0 as? UIImageView }
                    return posters.allSatisfy(\.isHidden)
                }
                return true
            }
        }
        pendingCapture = name
        writeReport()
        try await wait("capture acknowledgement " + name, seconds: 60) {
            FileManager.default.fileExists(atPath: documents.appendingPathComponent("ack-" + name).path)
        }
        captures.append(name)
        pendingCapture = nil
        writeReport()
    }

    private func run() async throws {
        try await wait("login begins decoding", seconds: 15) { (frames["login-backgroud"] ?? 0) > 4 }
        try await capture("login-start")
        try await wait("first login loop before encoded black tail", seconds: 16) { (wraps["login-backgroud"] ?? 0) >= 1 }
        try await capture("login-after-loop")
        try await wait("second login loop", seconds: 16) { (wraps["login-backgroud"] ?? 0) >= 2 }
        try await capture("login-second-loop")

        scenario.resource = .main
        scenario.showNavigation = true
        try await wait("main begins decoding", seconds: 15) { (frames["app-backgroud"] ?? 0) > 4 }
        try await capture("main-baseline")
        scenario.clearNavigation = true
        try await Task.sleep(nanoseconds: 800_000_000)
        try await capture("main-tab-0")
        for tab in [1, 2, 0] {
            withAnimation(.easeInOut(duration: 0.32)) { scenario.selectedTab = tab }
            try await Task.sleep(nanoseconds: 800_000_000)
            try await capture("main-tab-\(tab)-settled")
        }
        try await wait("main loops while settled tabs remain visible", seconds: 15) { (wraps["app-backgroud"] ?? 0) >= 1 }
        try await capture("main-after-loop")
        try require(playerIDs.count == 1, "Background must retain one AVQueuePlayer while changing source/tabs")
        try require((frames["login-backgroud"] ?? 0) > 200, "Insufficient actual decoded login frames")
        try require((frames["app-backgroud"] ?? 0) > 100, "Insufficient actual decoded main frames")
        try require(failures.isEmpty, "Playback failures: " + failures.joined(separator: "; "))
    }

    private func layers(in layer: CALayer) -> [AVPlayerLayer] {
        (layer as? AVPlayerLayer).map { [$0] } ?? (layer.sublayers ?? []).flatMap { layers(in: $0) }
    }

    private func sample() {
        guard let window else { return }
        let videoLayers = layers(in: window.layer)
        guard videoLayers.count == 1, let layer = videoLayers.first,
              let player = layer.player, let item = player.currentItem,
              let url = (item.asset as? AVURLAsset)?.url else { writeReport(); return }
        playerIDs.insert(ObjectIdentifier(player))
        let resource = url.deletingPathExtension().lastPathComponent
        let time = item.currentTime().seconds
        guard time.isFinite else { return }
        if let previous = previousTime[resource], time + 0.5 < previous {
            wraps[resource, default: 0] += 1
        }
        previousTime[resource] = time
        if observedItem !== item {
            if let previousItem = observedItem, let output { previousItem.remove(output) }
            let replacement = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(replacement)
            observedItem = item
            output = replacement
        }
        var average: Double?
        var decodedFrameTime = CMTime.invalid
        if let output, let pixels = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: &decodedFrameTime) {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
                let stride = CVPixelBufferGetBytesPerRow(pixels)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                var sum = 0.0, count = 0
                for y in Swift.stride(from: 0, to: height, by: max(1, height / 20)) {
                    for x in Swift.stride(from: 0, to: width, by: max(1, width / 20)) {
                        let offset = y * stride + x * 4
                        sum += Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])
                        count += 3
                    }
                }
                average = sum / Double(max(count, 1))
                frames[resource, default: 0] += 1
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        // The wall-clock item position may overshoot while the queue advances.
        // Verify the decoded frame timestamp; allow one source frame for the
        // independently sampled player clock during the queue handoff.
        if resource == "login-backgroud", decodedFrameTime.isValid, decodedFrameTime.seconds >= 11.6 {
            failures.append("Decoded login frame entered black tail at \(decodedFrameTime.seconds)")
        }
        if resource == "login-backgroud", time >= 11.6 + 1.0 / 25.0 {
            failures.append("Login queue did not advance at \(time)")
        }
        if resource == "login-backgroud", let average, average < 2 {
            failures.append("Decoded login frame was black at \(time)")
        }
        if item.status == .failed { failures.append("AVPlayerItem failed") }
        samples.append(["resource": resource, "time": time, "readyForDisplay": layer.isReadyForDisplay, "layerHidden": layer.isHidden,
                        "playerRate": player.rate, "averageRGB": average ?? -1,
                        "tab": scenario.selectedTab, "clearNavigation": scenario.clearNavigation])
        writeReport()
    }

    private func writeReport() {
        let report: [String: Any] = ["result": result, "pendingCapture": pendingCapture ?? "", "captures": captures,
            "wraps": wraps, "decodedFrames": frames, "playerCount": playerIDs.count, "failures": failures,
            "screenPoints": [window?.bounds.width ?? 0, window?.bounds.height ?? 0], "samples": samples,
            "scope": "iOS Simulator UIKit/SwiftUI/AVFoundation harness using production background and navigation-surface helper; not full app authentication or physical iPhone execution"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}

@MainActor
final class CheckAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let driver = VideoDriver()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: VideoCheckRoot(scenario: driver.scenario))
        window.makeKeyAndVisible()
        self.window = window
        driver.start(in: window)
        return true
    }
}

@main enum VideoCheckMain {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(CheckAppDelegate.self))
    }
}
