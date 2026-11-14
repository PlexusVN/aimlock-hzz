import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Aimlock Hzz · charcoal / silver
// Shared presentation tokens; legacy names remain so feature behavior stays intact.

enum AppTheme {
    // MARK: Monochrome palette
    static let ink          = Color(hex: 0xF5F5F4)
    static let inkSecondary = Color(hex: 0x222426)
    static let paper        = Color(hex: 0x171819)
    static let paperMuted   = Color(hex: 0x1B1D1F)
    static let paperRaised  = Color(hex: 0x222426)
    static let grey900      = Color(hex: 0xF5F5F4)
    static let grey700      = Color(hex: 0xD8D9DC)
    static let grey600      = Color(hex: 0xC7C9CC)
    static let grey500      = Color(hex: 0xB6B8BC)
    static let grey400      = Color(hex: 0x8B8E93)
    static let grey300      = Color(hex: 0x55585E)
    static let grey200      = Color(hex: 0x3A3D41)
    static let grey100      = Color(hex: 0x2C2F33)
    static let grey50       = Color(hex: 0x222426)

    // Semantic status palette: chỉ dùng để truyền đạt trạng thái.
    static let statusSuccess = Color(hex: 0xA7C7B1)
    static let statusInfo    = Color(hex: 0xD8D9DC)
    static let statusWarning = Color(hex: 0xD8BD86)
    static let statusError   = Color(hex: 0xE3A4A4)

    static let positive     = statusSuccess
    static let negative     = statusError

    // MARK: Borders
    static let borderHairline = Color(hex: 0x3A3D41)
    static let borderStrong   = Color(hex: 0x8B8E93)

    // MARK: Spacings / sizes
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18

    // Background helpers
    static let pageBackground: Color = paper
    static let consoleBackground: Color = paperMuted

    /// Legacy colors kept for backward compatibility with existing helpers
    /// (AirLiftSettingsSection, PatchProjectEditorView, v.v.).
    /// Sử dụng `.ink` thay vì các giá trị này cho code mới.
    static let accent = ink
    static let accentLight = ink

    /// Aliases cho các tên cũ - trỏ về palette trắng-đen 2026
    static let cyberCyan  = Color(hex: 0xF5F5F4)
    static let cyberBlue  = Color(hex: 0xD8D9DC)
    static let cyberPurple = Color(hex: 0xD8D9DC)
    static let cyberViolet = Color(hex: 0xD8D9DC)
    static let cyberPink   = Color(hex: 0xB6B8BC)
    static let cyberGreen  = Color(hex: 0xA7C7B1)
    static let cyberOLED   = paper
    static let cyberSurface = paperMuted

    static let cyberGradient = LinearGradient(
        colors: [cyberCyan, cyberViolet, cyberPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cyberBorderGradient = LinearGradient(
        colors: [cyberCyan.opacity(0.70), cyberViolet.opacity(0.48), cyberPink.opacity(0.34)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cyberSubtleBorder = LinearGradient(
        colors: [cyberCyan.opacity(0.28), cyberPink.opacity(0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Gaming palette (compatibility names for existing screens)
    static let gamingBackground = Color(hex: 0x171819)
    static let gamingBackgroundRaised = Color(hex: 0x1B1D1F)
    static let gamingSurface = Color(hex: 0x222426)
    static let gamingSurfaceRaised = Color(hex: 0x2C2F33)
    static let gamingBlue = Color(hex: 0xF5F5F4)
    static let gamingBlueBright = Color(hex: 0xF5F5F4)
    static let gamingViolet = Color(hex: 0xD8D9DC)
    static let gamingPink = Color(hex: 0xB6B8BC)
    static let gamingText = Color(hex: 0xF5F5F4)
    static let gamingTextSecondary = Color(hex: 0xB6B8BC)
    static let gamingBorder = Color(hex: 0x3A3D41)

    static let gamingAccentGradient = LinearGradient(
        colors: [gamingBlue, gamingBlueBright, gamingViolet, gamingPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let gamingBorderGradient = LinearGradient(
        colors: [gamingBlueBright.opacity(0.70), gamingViolet.opacity(0.48), gamingPink.opacity(0.30)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static var gamingTabSpring: Animation {
        MotionPreference.isReduced ? .linear(duration: 0.01) : .spring(response: 0.30, dampingFraction: 0.90, blendDuration: 0.06)
    }
    static var gamingContentFade: Animation {
        .easeOut(duration: MotionPreference.isReduced ? 0.08 : 0.16)
    }

    // MARK: Surfaces / Materials
    /// Floating capsule material for tabbar (iOS 16-25 fallback)
    @ViewBuilder
    static func capsuleBar(tint: Color = ink) -> some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule().stroke(tint.opacity(0.16), lineWidth: 1)
            )
    }

    /// Charcoal card with a neutral hairline border.
    @ViewBuilder
    static func cardSurface(cornerRadius: CGFloat = 12) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(paperRaised)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderHairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
    }

    /// Liquid Glass / iOS 16+ equivalent: ultraThinMaterial on capsule
    /// Khi build bằng Xcode 26+ với iOS 26 SDK, có thể kích hoạt glassEffect thật ở đây.
    static func liquidGlassCapsule<S: Shape>(shape: S, interactive: Bool = true) -> some View {
        shape.fill(.ultraThinMaterial)
            .overlay(
                shape.stroke(borderHairline, lineWidth: 1)
            )
    }
}

// MARK: - Gaming surfaces

struct GamingBackdrop: View {
    @Environment(\.hasAppVideoBackground) private var hasAppVideoBackground

    var body: some View {
        ZStack {
            if hasAppVideoBackground {
                // A single player at the WindowGroup owns the moving image.
                // Tabs keep their layout but add no duplicate decoder/layer.
                Color.clear
            } else {
                AppTheme.gamingBackground
                LinearGradient(
                    colors: [Color(hex: 0x242628), AppTheme.gamingBackground, Color(hex: 0x111213)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.035), Color.clear],
                    center: .init(x: 0.5, y: 0.32),
                    startRadius: 0,
                    endRadius: 380
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct GamingPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.975

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !MotionPreference.isReduced ? scale : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(MotionPreference.pressAnimation, value: configuration.isPressed)
    }
}

// MARK: - Gaming reticle

/// Shared vector mark for feature navigation and the gaming controls.
struct AimlockReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side / 24, y: origin.y + y * side / 24)
        }
        var path = Path()
        let corners: [[(CGFloat, CGFloat)]] = [
            [(3, 8), (3, 3), (8, 3)],
            [(16, 3), (21, 3), (21, 8)],
            [(21, 16), (21, 21), (16, 21)],
            [(8, 21), (3, 21), (3, 16)]
        ]
        for corner in corners {
            path.move(to: point(corner[0].0, corner[0].1))
            for vertex in corner.dropFirst() {
                path.addLine(to: point(vertex.0, vertex.1))
            }
        }
        path.addEllipse(in: CGRect(x: point(6, 6).x, y: point(6, 6).y,
                                   width: side / 2, height: side / 2))
        let arms: [[(CGFloat, CGFloat)]] = [
            [(12, 1), (12, 7)], [(12, 17), (12, 23)],
            [(1, 12), (7, 12)], [(17, 12), (23, 12)]
        ]
        for arm in arms {
            path.move(to: point(arm[0].0, arm[0].1))
            path.addLine(to: point(arm[1].0, arm[1].1))
        }
        path.move(to: point(12, 10))
        path.addLine(to: point(14, 12))
        path.addLine(to: point(12, 14))
        path.addLine(to: point(10, 12))
        path.closeSubpath()
        return path
    }
}

struct AimlockReticleIcon: View {
    var body: some View {
        AimlockReticleShape()
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .square, lineJoin: .miter))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

// MARK: - Logo

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "NovaXLogo")
                ?? UIImage(named: "AppIcon60x60")
                ?? Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
                ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "bolt.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.gamingSurfaceRaised)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
    }
}

// MARK: - Reusable building blocks

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.ink
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.08))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            AppTheme.grey50,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Button styles

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !MotionPreference.isReduced ? 0.975 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(MotionPreference.pressAnimation, value: configuration.isPressed)
    }
}

/// Secondary charcoal action.
struct OutlineButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(AppTheme.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.gamingBorderGradient, lineWidth: 1)
            )
            .foregroundStyle(AppTheme.gamingText)
            .scaleEffect(configuration.isPressed && !MotionPreference.isReduced ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(MotionPreference.pressAnimation, value: configuration.isPressed)
    }
}

/// Silver primary action with a high-contrast charcoal label.
struct PrimaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(AppTheme.gamingAccentGradient)
            .foregroundStyle(AppTheme.gamingBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.20), radius: 10, x: 0, y: 5)
            .scaleEffect(configuration.isPressed && !MotionPreference.isReduced ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(MotionPreference.pressAnimation, value: configuration.isPressed)
    }
}

/// Legacy button styles preserved for backward compatibility
/// (AirLiftSettingsSection, PatchProjectEditorView, FilesTabControls v.v.)
/// Phiên bản đơn sắc trắng-đen theo design 2026.
struct PremiumButtonStyle: ButtonStyle {
    var color: Color = AppTheme.ink
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(
                    colors: [AppTheme.gamingSurfaceRaised, AppTheme.gamingSurface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.16),
                    radius: configuration.isPressed ? 3 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed && !MotionPreference.isReduced ? 0.975 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(MotionPreference.pressAnimation, value: configuration.isPressed)
    }
}

struct CyberGlowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(AppTheme.gamingSurfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.16),
                radius: configuration.isPressed ? 3 : 10,
                y: configuration.isPressed ? 1 : 5
            )
            .scaleEffect(configuration.isPressed && !MotionPreference.isReduced ? 0.975 : 1.0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1.0) : 0.4)
            .animation(MotionPreference.pressAnimation, value: configuration.isPressed)
    }
}

/// Disabled state (placeholder, vẫn giữ kích thước)
struct PrimaryButtonStyleDisabled: ButtonStyle {
    var cornerRadius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppTheme.grey200)
            .foregroundStyle(AppTheme.grey500)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Toast

struct ToastInfo: Equatable, Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var isSuccess: Bool
}

struct GlassToastModifier: ViewModifier {
    @Binding var toast: ToastInfo?
    @State private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                if let t = toast {
                    VStack {
                        HStack(spacing: 12) {
                            Image(systemName: t.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(t.isSuccess ? AppTheme.gamingBlueBright : AppTheme.statusError)
                                .shadow(
                                    color: (t.isSuccess ? AppTheme.gamingBlue : AppTheme.statusError).opacity(0.45),
                                    radius: 8
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title)
                                    .font(.system(size: 14, weight: .bold, design: .default))
                                    .foregroundColor(AppTheme.gamingText)
                                Text(t.message)
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.gamingTextSecondary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(AppTheme.gamingSurface.opacity(0.93))
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    t.isSuccess
                                        ? AppTheme.gamingBorderGradient
                                        : LinearGradient(
                                            colors: [AppTheme.statusError.opacity(0.72), Color.white.opacity(0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: Color.black.opacity(0.25),
                            radius: 16,
                            y: 10
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 60)
                        .offset(y: dragOffset < 0 ? dragOffset : 0)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if value.translation.height < 0 {
                                        dragOffset = value.translation.height
                                    }
                                }
                                .onEnded { value in
                                    if value.translation.height < -20 {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                            toast = nil
                                        }
                                    }
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        dragOffset = 0
                                    }
                                }
                        )
                        .transition(.move(edge: .top))
                        .id(t.id)

                        Spacer()
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                    if self.toast?.id == t.id {
                                        self.toast = nil
                                    }
                                }
                            }
                        }
                        .onTapGesture {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                toast = nil
                            }
                        }
                    }
                    .zIndex(100)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: toast?.id)
        )
    }
}

extension View {
    func glassToast(toast: Binding<ToastInfo?>) -> some View {
        self.modifier(GlassToastModifier(toast: toast))
    }
}

// MARK: - Haptics

enum Haptics {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy()  { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func soft()   { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.72) }
    static func rigid()  { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.82) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success(){ UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning(){ UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error()  { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Shared static backdrops

struct MeshBackground: View {
    var body: some View { GamingBackdrop() }
}

struct SplashBackdrop: View {
    var body: some View { GamingBackdrop() }
}

enum CommunityLinks {
    static func openTelegram(_ username: String) {
        let normalizedUsername = username.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard let appURL = URL(string: "tg://resolve?domain=\(normalizedUsername)"),
              let webURL = URL(string: "https://t.me/\(normalizedUsername)") else { return }

        UIApplication.shared.open(appURL, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(webURL)
            }
        }
    }

}

// MARK: - Geometry match helpers

/// Helper dùng chung cho logo morph: shared namespace constant
enum SplashGeometryNamespace {
    static let logo = "novax.splash.logo"
}

// MARK: - MotionReduce helper

enum MotionPreference {
    static var isReduced: Bool { UIAccessibility.isReduceMotionEnabled }
    static var pressAnimation: Animation {
        isReduced ? .easeOut(duration: 0.08) : .spring(response: 0.24, dampingFraction: 0.88)
    }
}
