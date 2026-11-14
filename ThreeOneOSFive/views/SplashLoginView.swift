//
//  SplashLoginView.swift
//  ThreeOneOSFive
//
//  GỘP Splash + Login thành 1 màn hình duy nhất (liền mạch, không có 2 màn hình tách biệt).
//  Shared logo transitions from the centered splash to the login header.
//  Authentication and loading sequence retain the original behavior.
//

import SwiftUI
import UIKit

struct SplashLoginView: View {
    @ObservedObject var auth: AuthManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updateManager: UpdateManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case loading          // Splash: Logo 112 ở giữa + progress bar chạy mượt mà bên dưới
        case transitioning    // Logo morph trong khi splash và login cùng tồn tại
        case ready            // Login: Logo morph 92 cố định ở trên đầu + form hiển thị đầy đủ
    }

    @State private var phase: Phase
    @State private var loadProgress: CGFloat = 0.05
    @State private var statusText: String = "Đang khởi tạo"
    @State private var pulseOpacity: Double = 0.35
    @State private var sheenOffset: CGFloat = -160

    // Gradual entrance cho màn hình splash
    @State private var splashLogoOpacity: Double = 0.0
    @State private var splashLogoScale: CGFloat = 0.90
    @State private var splashIdentityOpacity: Double = 0.0
    @State private var splashBottomOpacity: Double = 0.0
    @State private var splashLayerOpacity: Double = 1.0
    @State private var splashDetailsOffset: CGFloat = 0
    @State private var logoFrames: [SplashLogoSlot: CGRect] = [:]
    @State private var flightSource: CGRect?
    @State private var flightTarget: CGRect?
    @State private var logoFlightProgress: CGFloat = 0

    // Reveal animation cho form đăng nhập
    @State private var formOpacity: Double = 0.0
    @State private var formOffset: CGFloat = 18

    @State private var showKey: Bool = false
    @State private var showQuickSettings: Bool = false

    private static var hasCompletedInitialSplash = false

    init(auth: AuthManager) {
        self.auth = auth
        if Self.hasCompletedInitialSplash {
            _phase = State(initialValue: .ready)
            _formOpacity = State(initialValue: 1.0)
            _formOffset = State(initialValue: 0.0)
        } else {
            _phase = State(initialValue: .loading)
        }
    }

    var body: some View {
        ZStack {
            GamingBackdrop()

            // Measure the final logo slot before starting the flight. Keeping
            // this layout mounted avoids inserting a differently sized image
            // in the same transaction as the position animation.
            loginView
                .opacity(phase == .loading ? 0 : 1)
                .allowsHitTesting(phase == .ready)
                .accessibilityHidden(phase != .ready)
                .zIndex(1)

            if phase != .ready {
                splashView
                    .opacity(splashLayerOpacity)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .coordinateSpace(name: SplashLogoFramesKey.coordinateSpace)
        .onPreferenceChange(SplashLogoFramesKey.self) { frames in
            // The moving layer owns its transaction once the flight starts.
            // New layout measurements must not replace/cancel that animation.
            guard phase == .loading else { return }
            let measured = frames.filter { _, rect in
                rect.width > 0 && rect.height > 0 && rect.minX.isFinite && rect.minY.isFinite
            }
            guard measured != logoFrames else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { logoFrames = measured }
        }
        .overlay {
            if phase != .ready,
               let source = flightSource ?? logoFrames[.splash],
               let target = flightTarget ?? logoFrames[.login] {
                // One persistent image lives above both screens. Its layout
                // stays 112 pt; one animatable clock drives position AND scale.
                logoArtwork
                    .frame(width: 112, height: 112)
                    .overlay {
                        if !reduceMotion {
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.22), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .offset(x: sheenOffset)
                        }
                    }
                    .modifier(SplashLogoFlightModifier(
                        progress: logoFlightProgress,
                        introScale: reduceMotion ? 1 : splashLogoScale,
                        source: source,
                        target: target
                    ))
                    .opacity(splashLogoOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showQuickSettings) {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateManager)
        }
        .task(id: logoFrames[.splash] != nil && logoFrames[.login] != nil) {
            // Intro begins only after the persistent layer has both slots.
            guard logoFrames[.splash] != nil, logoFrames[.login] != nil else { return }
            await startLoadingSequence()
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.22), value: authErrorMessage)
    }

    // MARK: - Splash View (giao diện loading khởi động)

    private var splashView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            VStack(spacing: 24) {
                Color.clear
                    .frame(width: 112, height: 112)
                    .background(logoMeasurement(.splash))

                VStack(spacing: 10) {
                    Text("AIMLOCK HZZ")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(AppTheme.gamingText)
                        .tracking(1.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("POWERED BY AIMLOCK HZZ")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                        .tracking(1.8)
                }
                .opacity(splashIdentityOpacity)
                .offset(y: splashDetailsOffset)
            }

            VStack(spacing: 13) {
                HStack(spacing: 12) {
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text("\(Int(loadProgress * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.gamingText)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.gamingBorder)
                        Capsule()
                            .fill(AppTheme.gamingAccentGradient)
                            .frame(width: max(0, min(geo.size.width * loadProgress, geo.size.width)))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppTheme.gamingText)
                        .frame(width: 4, height: 4)
                        .opacity(reduceMotion ? 1 : pulseOpacity)
                    Text("Đang chuẩn bị giao diện")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 350)
            .background(AppTheme.gamingSurface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.gamingBorder, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .opacity(splashBottomOpacity)
            .offset(y: splashDetailsOffset)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 32)
        }
    }

    // MARK: - Login View (giao diện đăng nhập sau khi load xong)

    private var loginView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Quick settings remains available before authentication.
                HStack {
                    Button {
                        Haptics.light()
                        showQuickSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.gamingBlueBright)
                            .frame(width: 40, height: 40)
                            .background(Color(hex: 0x222426))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(hex: 0x3A3D41), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 4)
                                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cài đặt nhanh")

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .opacity(formOpacity)

                // Shared logo remains visible at the top of the login form.
                appLogoView(size: 92, cornerRadius: 12)
                    .opacity(phase == .ready ? 1 : 0)
                    .background(logoMeasurement(.login))
                    .padding(.top, 6)
                    .padding(.bottom, 16)

                brandTitle
                    .opacity(formOpacity)
                    .offset(y: reduceMotion ? 0 : formOffset * 0.5)
                    .animation(loginRevealAnimation(delay: 0), value: formOpacity)

                // Silver divider separates identity from the activation form.
                LinearGradient(
                    colors: [
                        Color.clear,
                        AppTheme.gamingBlueBright.opacity(0.50),
                        AppTheme.gamingPink.opacity(0.40),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 54, height: 1)
                .padding(.top, 20)
                .padding(.bottom, 30)
                .opacity(formOpacity)
                .animation(loginRevealAnimation(delay: 0.065), value: formOpacity)

                activationCard
                    .padding(.horizontal, 20)
                    .opacity(formOpacity)
                    .offset(y: reduceMotion ? 0 : formOffset)
                    .animation(loginRevealAnimation(delay: 0.13), value: formOpacity)

                activateButton
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .opacity(formOpacity)
                    .offset(y: reduceMotion ? 0 : formOffset)
                    .animation(loginRevealAnimation(delay: 0.195), value: formOpacity)

                deviceCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
                    .opacity(formOpacity)
                    .offset(y: reduceMotion ? 0 : formOffset)
                    .animation(loginRevealAnimation(delay: 0.26), value: formOpacity)
            }
        }
        .adaptiveScrollBounceBehavior()
    }

    // MARK: - Reusable App Logo View (Avatar hiển thị sắc nét)

    private var logoArtwork: some View {
        ZStack {
            Color(hex: 0x222426)

            if let icon = UIImage(named: "NovaXLogo")
                ?? UIImage(named: "AppIcon60x60")
                ?? Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
                ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(AppTheme.gamingBlueBright)
            }
        }
        .clipped()
    }

    private func appLogoView(size: CGFloat, cornerRadius: CGFloat) -> some View {
        logoArtwork
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppTheme.gamingBlueBright.opacity(0.40), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.55), radius: 15, x: 0, y: 10)
    }

    private func logoMeasurement(_ slot: SplashLogoSlot) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SplashLogoFramesKey.self, value: [
                slot: geometry.frame(in: .named(SplashLogoFramesKey.coordinateSpace))
            ])
        }
    }

    // MARK: - Brand title

    private var brandTitle: some View {
        VStack(spacing: 9) {
            Text("AIMLOCK HZZ")
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(AppTheme.gamingText)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("LICENSE ACCESS · iOS")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.gamingTextSecondary)
                .tracking(1.8)
        }
    }

    // MARK: - Activation card

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.gamingBlueBright.opacity(0.45), lineWidth: 1)
                        .background(
                            LinearGradient(
                                colors: [
                                    AppTheme.gamingBlue.opacity(0.18),
                                    AppTheme.gamingViolet.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: AppTheme.gamingBlue.opacity(0.20), radius: 6, x: 0, y: 0)
                        .frame(width: 42, height: 42)

                    Image(systemName: "key.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.gamingBlueBright)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("KÍCH HOẠT HỆ THỐNG")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.gamingBlueBright)
                    Text("Nhập license key để bắt đầu")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xB6B8BC))
                }

                Spacer()
                statusPill
            }

            Rectangle()
                .fill(Color(hex: 0x3A3D41).opacity(0.80))
                .frame(height: 1)
                .padding(.vertical, 18)

            Text("MÃ KÍCH HOẠT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: 0xD8D9DC))
                .tracking(0.7)
                .padding(.bottom, 9)

            HStack(spacing: 11) {
                Image(systemName: "key.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.gamingBlue)
                    .frame(width: 22)

                Group {
                    if showKey {
                        TextField("", text: $auth.licenseKey, prompt: Text("Nhập license key").foregroundColor(Color(hex: 0x8B8E93)))
                    } else {
                        SecureField("", text: $auth.licenseKey, prompt: Text("Nhập license key").foregroundColor(Color(hex: 0x8B8E93)))
                    }
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(Color(hex: 0xF5F5F4))

                Button {
                    Haptics.light()
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.gamingBlue)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .frame(height: 58)
            .background(Color(hex: 0x1B1D1F))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(activationInputBorderColor, lineWidth: 1)
            )

            if let errorMessage = authErrorMessage {
                authErrorBanner(errorMessage)
                    .padding(.top, 12)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                    )
            } else if auth.authState == .verified {
                authSuccessBanner
                    .padding(.top, 12)
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HWID")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color(hex: 0xB6B8BC))
                    Text(auth.hwid.isEmpty ? "Chưa sẵn sàng" : auth.hwid)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xD8D9DC))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    Haptics.light()
                    UIPasteboard.general.string = auth.hwid.isEmpty
                        ? "Aimlock Hzz · HWID\niOS=\(AppInfo.osVersion) (\(AppInfo.osBuild))\n" + (auth.hwidFailure ?? "Đang chờ định danh thiết bị.")
                        : auth.hwid
                    Haptics.success()
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.gamingBlueBright)
                        .frame(width: 36, height: 36)
                        .background(Color(hex: 0x222426))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.gamingBlueBright.opacity(0.30), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color(hex: 0x1B1D1F))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(hex: 0x2C2F33), lineWidth: 1)
            )
            .padding(.top, 14)
        }
        .padding(20)
        .background(AppTheme.gamingSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.gamingBlueBright.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 12)

    }

    private var authErrorMessage: String? {
        guard case .error(let message) = auth.authState else { return nil }
        return message
    }

    private var activationInputBorderColor: Color {
        switch auth.authState {
        case .verified: return Color(hex: 0xA7C7B1)
        case .loading:  return AppTheme.gamingBlueBright
        case .error:    return Color(hex: 0xE3A4A4)
        case .idle:     return Color(hex: 0x3A3D41)
        }
    }

    private var authStatusPresentation: (label: String, foreground: Color, dot: Color, borderColor: Color) {
        switch auth.authState {
        case .verified:
            return ("ON", Color(hex: 0xA7C7B1), Color(hex: 0xA7C7B1), Color(hex: 0xA7C7B1).opacity(0.40))
        case .loading:
            return ("WAIT", AppTheme.gamingBlueBright, AppTheme.gamingBlueBright, AppTheme.gamingBlueBright.opacity(0.40))
        case .error:
            return ("ERROR", Color(hex: 0xE3A4A4), Color(hex: 0xE3A4A4), Color(hex: 0x3A3D41))
        case .idle:
            return ("OFF", AppTheme.gamingTextSecondary, AppTheme.gamingTextSecondary, AppTheme.gamingBorder)
        }
    }

    private func authErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: 0xE3A4A4))

            VStack(alignment: .leading, spacing: 4) {
                Text("KHÔNG THỂ XÁC THỰC")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.45)
                    .foregroundStyle(Color(hex: 0xE3A4A4))

                Text(message)
                    .textSelection(.enabled)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(hex: 0xD8D9DC))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color(hex: 0xE3A4A4).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: 0xE3A4A4).opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lỗi xác thực: \(message)")
    }

    private var authSuccessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(hex: 0xA7C7B1))

            VStack(alignment: .leading, spacing: 4) {
                Text("ĐĂNG NHẬP THÀNH CÔNG")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.45)
                    .foregroundStyle(Color(hex: 0xA7C7B1))
                Text("Đang mở giao diện chính của Aimlock Hzz…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(hex: 0xD8D9DC))
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color(hex: 0xA7C7B1).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: 0xA7C7B1).opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Đăng nhập thành công. Đang mở Aimlock Hzz.")
    }

    private var statusPill: some View {
        let presentation = authStatusPresentation
        return HStack(spacing: 4) {
            Circle()
                .fill(presentation.dot)
                .frame(width: 6, height: 6)
            Text(presentation.label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(presentation.foreground)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(hex: 0x1B1D1F))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(presentation.borderColor, lineWidth: 1)
        )
    }

    private var isLicenseEmpty: Bool {
        auth.licenseKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var activateButton: some View {
        Button {
            Haptics.medium()
            Task { await auth.login() }
        } label: {
            HStack(spacing: 9) {
                if case .loading(let text) = auth.authState {
                    ProgressView()
                        .tint(AppTheme.gamingBackground)
                        .scaleEffect(0.85)
                    Text(text)
                        .font(.system(size: 15, weight: .semibold))
                } else if auth.authState == .verified {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("ĐĂNG NHẬP THÀNH CÔNG")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(0.2)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("XÁC THỰC NGAY")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(0.2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(isLicenseEmpty ? AppTheme.gamingTextSecondary : AppTheme.gamingBackground)
            .background(
                Group {
                    if isLicenseEmpty {
                        Color(hex: 0x3A3D41)
                    } else {
                        LinearGradient(
                            colors: [
                                AppTheme.gamingBlue,
                                AppTheme.gamingViolet,
                                AppTheme.gamingViolet,
                                AppTheme.gamingPink
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isLicenseEmpty ? Color(hex: 0x3A3D41) : Color.white.opacity(0.20), lineWidth: 1)
            )
            .shadow(
                color: isLicenseEmpty ? Color.clear : Color.black.opacity(0.20),
                radius: 12, x: 0, y: 6
            )

        }
        .buttonStyle(GamingPressButtonStyle(scale: 0.985))
        .disabled(isLicenseEmpty || auth.authState == .verified)
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "iphone")
                    .font(.system(size: 13, weight: .semibold))
                Text("THÔNG TIN THIẾT BỊ")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(AppTheme.gamingBlueBright)

            Rectangle()
                .fill(Color(hex: 0x3A3D41).opacity(0.80))
                .frame(height: 1)

            deviceRow("Phiên bản iOS:", value: "iOS \(AppInfo.osVersion)",
                      isMonoValue: true, valueColor: AppTheme.gamingBlueBright)
            deviceRow("Trạng thái hỗ trợ:",
                      value: appState.accessLevelDescription.uppercased(),
                      isMonoValue: true,
                      valueColor: appState.isSupported ? Color(hex: 0xA7C7B1) : Color(hex: 0xE3A4A4))
        }
        .padding(19)
        .background(AppTheme.gamingSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.gamingBlueBright.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 10)
    }

    private func deviceRow(_ label: String, value: String, isMonoValue: Bool = false, valueColor: Color = AppTheme.gamingBlueBright) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0xD8D9DC))
            Spacer()
            Text(value)
                .font(.system(size: isMonoValue ? 12 : 14, weight: .semibold, design: isMonoValue ? .monospaced : .default))
                .foregroundStyle(valueColor)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Loading sequence (Hiệu ứng load từ từ + thanh tiến trình mượt mà)

    private func loginRevealAnimation(delay: Double) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.08) }
        return .timingCurve(0.22, 0.75, 0.30, 1.0, duration: 0.50)
            .delay(delay)
    }

    @MainActor
    private func startLoadingSequence() async {
        guard phase == .loading else { return }

        // SwiftUI interpolates at the display refresh rate; no per-frame timers.
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseOpacity = 1.0
            }
        }

        // 1. Hiệu ứng load từ từ: Logo fade in từ từ 0 -> 1 và scale từ 0.90 -> 1.0 trong 0.7s
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) {
            splashLogoOpacity = 1.0
            splashLogoScale = 1.0
        }

        // Vệt sáng đơn sắc lướt qua mặt logo
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.15).delay(0.2)) {
            sheenOffset = 160
        }

        // Tên thương hiệu fade in nhẹ sau 0.2s
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(0.2)) {
            splashIdentityOpacity = 1.0
        }

        // Thanh tiến trình và status fade in sau 0.3s
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.3)) {
            splashBottomOpacity = 1.0
        }

        // 2. Thanh tiến trình chạy từ từ, mượt mà qua các chặng
        do {
            // Chặng 1: 0% -> 45% (Đang khởi tạo)
            try await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                loadProgress = 0.45
                statusText = "Đang khởi tạo"
            }

            // Chặng 2: 45% -> 80% (Đang chuẩn bị không gian làm việc)
            try await Task.sleep(nanoseconds: 480_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.48)) {
                loadProgress = 0.80
                statusText = "Đang chuẩn bị không gian làm việc"
            }

            // Chặng 3: 80% -> 100% (Sẵn sàng)
            try await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                loadProgress = 1.0
                statusText = "Sẵn sàng"
            }

            // Đợi thanh chạm 100% trọn vẹn
            try await Task.sleep(nanoseconds: 380_000_000)

            // Đánh dấu đã qua màn hình splash lần đầu
            Self.hasCompletedInitialSplash = true

            // Freeze measured endpoints so keyboard/size changes cannot split
            // the flight into a layout move followed by a separate resize.
            flightSource = logoFrames[.splash]
            flightTarget = logoFrames[.login]
            var handoff = Transaction(animation: nil)
            handoff.disablesAnimations = true
            withTransaction(handoff) { phase = .transitioning }

            // Match the preview timeline: details fade at t=0, logo flight
            // at +0.08 for 0.74 s, background fade at +0.18 for 0.50 s.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                splashBottomOpacity = 0.0
                splashIdentityOpacity = 0.0
                splashDetailsOffset = reduceMotion ? 0 : -6
                if reduceMotion { splashLogoOpacity = 0 }
            }

            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.50).delay(0.18)) {
                splashLayerOpacity = 0.0
            }

            // Let the phase/layout transaction commit before animating the
            // already mounted layer. This is also the preview's 80 ms lead-in.
            try await Task.sleep(nanoseconds: 80_000_000)
            if !reduceMotion, flightSource != nil, flightTarget != nil {
                withAnimation(.linear(duration: 0.74)) {
                    logoFlightProgress = 1
                }
                try await Task.sleep(nanoseconds: 740_000_000)
            }
            try Task.checkCancellation()
            // Both copies now occupy the same 92 pt target. Swap visibility
            // without a new resize animation; the inline logo then scrolls.
            withTransaction(handoff) { phase = .ready }

            // Mỗi khối dùng delay riêng để tạo hiệu ứng stagger giống bản HTML.
            formOpacity = 1.0
            formOffset = 0.0
        } catch {
            // The view's task is canceled when authentication navigates away.
            // Do not keep mutating a disappearing splash or reveal its form.
        }
    }
}

private enum SplashLogoSlot: Hashable {
    case splash, login
}

private struct SplashLogoFramesKey: PreferenceKey {
    static let coordinateSpace = "AimlockSplashLogoSpace"
    static let defaultValue: [SplashLogoSlot: CGRect] = [:]

    static func reduce(value: inout [SplashLogoSlot: CGRect], nextValue: () -> [SplashLogoSlot: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SplashLogoFlightModifier: AnimatableModifier {
    var progress: CGFloat
    var introScale: CGFloat
    let source: CGRect
    let target: CGRect

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, introScale) }
        set { progress = newValue.first; introScale = newValue.second }
    }

    func body(content: Content) -> some View {
        // GSAP power3.inOut is quartic. Evaluate it once on SwiftUI's native
        // linear clock and reuse the result for every geometric component.
        let clock = min(max(progress, 0), 1)
        let eased = clock < 0.5
            ? 8 * clock * clock * clock * clock
            : 1 - pow(-2 * clock + 2, 4) / 2
        let width = source.width + (target.width - source.width) * eased
        let scale = max(width / 112, 0.001)
        let corner = (16 + (12 - 16) * eased) / scale
        let center = CGPoint(
            x: source.midX + (target.midX - source.midX) * eased,
            y: source.midY + (target.midY - source.midY) * eased
        )

        content
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(AppTheme.gamingBlueBright.opacity(0.40), lineWidth: 1 / scale))
            .shadow(color: Color.black.opacity(0.55), radius: 15 / scale, x: 0, y: 10 / scale)
            .scaleEffect(scale * introScale)
            .position(center)
    }
}

extension View {
    @ViewBuilder
    fileprivate func adaptiveScrollBounceBehavior() -> some View {
        self
    }
}
