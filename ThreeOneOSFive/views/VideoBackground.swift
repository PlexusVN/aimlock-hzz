import SwiftUI
import UIKit
import AVFoundation

enum AppBackgroundVideo: String {
    case login = "login-backgroud"
    case main = "app-backgroud"

    func resourceURL(extension fileExtension: String, poster: Bool = false) -> URL? {
        let name = rawValue + (poster ? "-poster" : "")
        return Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Backgrounds")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/Backgrounds")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }
}

private struct AppVideoBackgroundEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hasAppVideoBackground: Bool {
        get { self[AppVideoBackgroundEnvironmentKey.self] }
        set { self[AppVideoBackgroundEnvironmentKey.self] = newValue }
    }
}

/// One native decoder behind the entire app. The original bundled MP4 is read
/// directly; no export, downsampling, bitrate cap or display-frame timer runs.
struct AppVideoBackdrop: View {
    let video: AppBackgroundVideo
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppTheme.gamingBackground
            BackgroundVideoSurface(video: video, isActive: scenePhase == .active, reduceMotion: reduceMotion)
            Color.black.opacity(0.25)
            LinearGradient(colors: [.clear, .black.opacity(0.40)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct BackgroundVideoSurface: UIViewRepresentable {
    let video: AppBackgroundVideo
    let isActive: Bool
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> BackgroundVideoView {
        let view = BackgroundVideoView()
        context.coordinator.attach(view)
        context.coordinator.update(video: video, isActive: isActive, reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ uiView: BackgroundVideoView, context: Context) {
        context.coordinator.update(video: video, isActive: isActive, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ uiView: BackgroundVideoView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private weak var view: BackgroundVideoView?
        private var selectedVideo: AppBackgroundVideo?
        private var hasFailed = false
        private var active = false
        private var motionReduced = false
        private var generation = 0
        private var itemObservation: NSKeyValueObservation?
        private var currentItemObservation: NSKeyValueObservation?
        private var displayObservation: NSKeyValueObservation?
        private var loopObservation: NSKeyValueObservation?
        private var failureNotification: NSObjectProtocol?

        init() {
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            // Advance to the next queued item; the looper keeps another pass ready.
            player.actionAtItemEnd = .advance
            // Background video must not configure AVAudioSession: AirLift's
            // existing keepalive/audio behavior owns that separate session.
        }

        func attach(_ view: BackgroundVideoView) {
            self.view = view
            view.playerLayer.player = player
            displayObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updatePresentation() }
            }
            currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.observeCurrentItem() }
            }
        }

        func update(video: AppBackgroundVideo, isActive: Bool, reduceMotion: Bool) {
            active = isActive
            motionReduced = reduceMotion
            if selectedVideo != video {
                selectedVideo = video
                load(video)
            }
            updatePlayback()
        }

        private func load(_ video: AppBackgroundVideo) {
            generation += 1
            player.pause()
            looper?.disableLooping()
            looper = nil
            loopObservation = nil
            itemObservation = nil
            removeFailureNotification()
            player.removeAllItems()
            hasFailed = false
            view?.poster.image = video.resourceURL(extension: "png", poster: true).flatMap {
                UIImage(contentsOfFile: $0.path)
            }
            view?.poster.isHidden = false
            view?.playerLayer.isHidden = true

            // In Reduce Motion the source-resolution lossless poster provides
            // a stable first frame without continuously decoding the video.
            guard !motionReduced else { return }
            preparePlayer(video)
        }

        private func preparePlayer(_ video: AppBackgroundVideo) {
            guard let url = video.resourceURL(extension: "mp4") else {
                hasFailed = true
                return
            }
            let item = AVPlayerItem(url: url)
            // AVPlayerLayer/AVFoundation retains source frame timing and color
            // conversion. The player layer is exactly the viewport bounds;
            // aspect fill uses only the minimum centered scale needed to cover
            // them, without any extra transform or scale on the video layer.
            // Differing aspect ratios crop edges rather than adding black bars.
            // The retained looper queues the next pass before the current one ends.
            let loop = AVPlayerLooper(player: player, templateItem: item)
            looper = loop
            let selectedGeneration = generation
            loopObservation = loop.observe(\.status, options: [.initial, .new]) { [weak self] loop, _ in
                guard loop.status == .failed else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == selectedGeneration else { return }
                    self.fail()
                }
            }
            observeCurrentItem()
        }

        private func observeCurrentItem() {
            itemObservation = nil
            removeFailureNotification()
            guard let item = player.currentItem else { return }
            let selectedGeneration = generation
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let failed = item.status == .failed
                DispatchQueue.main.async {
                    guard let self, self.generation == selectedGeneration else { return }
                    if failed { self.fail() } else { self.updatePlayback() }
                }
            }
            failureNotification = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == selectedGeneration else { return }
                    self.fail()
                }
            }
            updatePresentation()
        }

        private func updatePlayback() {
            if motionReduced {
                player.pause()
            } else if active && !hasFailed {
                if looper == nil, let selectedVideo { preparePlayer(selectedVideo) }
                if !hasFailed { player.play() }
            } else {
                player.pause()
            }
            updatePresentation()
        }

        private func updatePresentation() {
            guard let view else { return }
            let displayVideo = !motionReduced && !hasFailed && view.playerLayer.isReadyForDisplay
            // Keep the decoding layer attached while its first frame loads;
            // the opaque poster covers it until AVFoundation is ready.
            view.playerLayer.isHidden = motionReduced || hasFailed
            view.poster.isHidden = displayVideo
        }

        private func fail() {
            hasFailed = true
            player.pause()
            updatePresentation()
        }

        private func removeFailureNotification() {
            if let failureNotification { NotificationCenter.default.removeObserver(failureNotification) }
            failureNotification = nil
        }

        func stop() {
            generation += 1
            active = false
            player.pause()
            looper?.disableLooping()
            looper = nil
            loopObservation = nil
            itemObservation = nil
            currentItemObservation = nil
            displayObservation = nil
            removeFailureNotification()
            player.removeAllItems()
            view?.playerLayer.player = nil
            view = nil
        }
    }
}

@MainActor
private final class BackgroundVideoView: UIView {
    let playerLayer = AVPlayerLayer()
    let poster = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        addSubview(poster)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        poster.frame = bounds
    }
}
