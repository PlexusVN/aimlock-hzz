import SwiftUI
import UIKit

/// Compact identity, license, device details and session controls.
struct ProfileView: View {
    var showSystemDashboard: Binding<Bool>? = nil
    @EnvironmentObject private var auth: AuthManager
    @ObservedObject private var updateManager = UpdateManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLogoutModal: Bool = false
    @State private var appear: Bool = false

    private static let version: String = AppUpdateChecker.currentVersion
    private static let build: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    profileHero
                    licenseCard
                    updateCard
                    sessionCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 104)
                .opacity(appear ? 1 : 0)
                .offset(y: appear || reduceMotion ? 0 : 10)
            }
            .background(MeshBackground())
            .appVideoNavigationSurface()
            .navigationTitle("Hồ sơ")
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.gamingText)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Haptics.light()
                        showSystemDashboard?.wrappedValue = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.gamingText)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
                    }
                }
            }
            .overlay {
                if showLogoutModal {
                    logoutConfirmModal
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                        .zIndex(50)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.28)) { appear = true }
        }
    }

    // MARK: - Identity

    private var profileHero: some View {
        HStack(spacing: 13) {
            AppLogo(size: 56)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.grey400.opacity(0.5), lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                Text("Aimlock Hzz")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.gamingText)
                    .kerning(-0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("v\(Self.version) · Build \(Self.build)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.gamingTextSecondary)
                HStack(spacing: 7) {
                    Text(keyTypeLabel.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.gamingText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(AppTheme.gamingSurfaceRaised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    HStack(spacing: 5) {
                        Circle().fill(keyStatusColor).frame(width: 5, height: 5)
                        Text(keyStatusLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(keyStatusColor)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
    }

    // MARK: - License and device

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("License & thiết bị")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(AppTheme.gamingText)
            .padding(.bottom, 2)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LICENSE KEY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                    Text(auth.licenseKey.isEmpty ? "Chưa kích hoạt" : auth.licenseKey)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.gamingText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Haptics.light()
                    UIPasteboard.general.string = auth.licenseKey
                    Haptics.success()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.gamingText)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.gamingSurfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
                }
                .buttonStyle(GamingPressButtonStyle())
                .accessibilityLabel("Sao chép license key")
            }
            .padding(12)
            .background(AppTheme.gamingBackgroundRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.grey400.opacity(0.45), lineWidth: 1))

            HStack(spacing: 9) {
                Image(systemName: "iphone")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.gamingTextSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 5) {
                    Text("HWID THIẾT BỊ")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                    Text(auth.hwid)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.gamingText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(AppTheme.gamingBackgroundRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            infoGrid
        }
        .padding(14)
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
    }

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            infoCell(icon: "calendar", label: "Ngày kích hoạt",
                     value: formatDate(auth.expiresAt.map { $0.addingTimeInterval(-86400 * 30) }))
            infoCell(icon: "calendar.badge.clock", label: "Ngày hết hạn",
                     value: auth.expiresAt.map(formatDate) ?? "Không xác định")
            infoCell(icon: "shield.lefthalf.filled", label: "Loại key", value: keyTypeLabel)
            infoCell(icon: "timer", label: "Thời gian còn lại", value: remainingTime)
        }
    }

    private func infoCell(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(AppTheme.gamingTextSecondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.gamingText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(AppTheme.gamingBackgroundRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - App version

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppTheme.gamingText)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.gamingSurfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phiên bản & cập nhật")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.gamingText)
                    Text("\(Self.version) · Build \(Self.build)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Haptics.medium()
                    updateManager.checkForUpdate(showFeedback: true)
                } label: {
                    Group {
                        if updateManager.isChecking {
                            ProgressView().tint(AppTheme.gamingText).scaleEffect(0.8)
                        } else {
                            Text("Kiểm tra").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(AppTheme.gamingText)
                    .frame(minWidth: 64, minHeight: 44)
                    .background(AppTheme.gamingBackgroundRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
                }
                .buttonStyle(GamingPressButtonStyle())
                .disabled(updateManager.isChecking)
                .accessibilityLabel(updateManager.isChecking ? "Đang kiểm tra cập nhật" : "Kiểm tra cập nhật")
            }
            HStack(spacing: 5) {
                Circle().fill(updateStatusPresentation.color).frame(width: 5, height: 5)
                Text(updateStatusPresentation.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(updateStatusPresentation.color)
            }
            if let message = updateManager.lastCheckedMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(updateManager.updateOffer == nil ? AppTheme.statusSuccess : AppTheme.statusInfo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
    }

    // MARK: - Session

    private var sessionCard: some View {
        Button {
            Haptics.medium()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                showLogoutModal = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.statusError)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.statusError.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đăng xuất key")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.gamingText)
                    Text("Trở về màn hình nhập license key")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.gamingTextSecondary)
            }
            .frame(minHeight: 36)
            .padding(14)
            .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
        }
        .buttonStyle(GamingPressButtonStyle())
    }

    // MARK: - Logout modal

    private var logoutConfirmModal: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        showLogoutModal = false
                    }
                }

            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.statusError.opacity(0.25), AppTheme.gamingViolet.opacity(0.20)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 62, height: 62)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppTheme.statusError.opacity(0.5), lineWidth: 1)
                            )
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(AppTheme.statusError)
                    }
                    .padding(.top, 4)

                    Text("Đăng xuất key?")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(AppTheme.gamingText)
                        .kerning(-0.45)

                    Text("Phiên license hiện tại sẽ được xóa khỏi Aimlock Hzz và bạn sẽ trở về màn hình nhập key.")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.grey500)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.grey600)
                            .padding(.top, 1)
                        Text("Thao tác này không tự khôi phục những tệp đã áp dụng.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.grey700)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.grey50)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.grey200, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            showLogoutModal = false
                        }
                    } label: {
                        Text("Hủy")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.grey700)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AppTheme.grey50)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppTheme.grey200, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        performLogout()
                    } label: {
                        Text("Đăng xuất")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                LinearGradient(
                                    colors: [AppTheme.statusError, Color(hex: 0xE11D48)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: AppTheme.statusError.opacity(0.3), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .background(AppTheme.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.gamingBorderGradient.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.20), radius: 40, x: 0, y: 18)
            .padding(.horizontal, 28)
        }
    }

    private func performLogout() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            showLogoutModal = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            auth.logout()
        }
    }

    // MARK: - Helpers

    private var keyTypeLabel: String {
        switch auth.keyType {
        case .vip, .admin: return "Premium"
        case .pro:         return "Pro"
        case .basic:       return "Basic"
        }
    }

    private var keyStatusLabel: String {
        switch auth.authState {
        case .verified: return "Đang hoạt động"
        case .loading:  return "Đang xác thực…"
        case .error:    return "Lỗi xác thực"
        case .idle:     return "Chưa xác thực"
        }
    }

    private var keyStatusColor: Color {
        switch auth.authState {
        case .verified: return AppTheme.statusSuccess
        case .loading:  return AppTheme.statusInfo
        case .error, .idle: return AppTheme.statusError
        }
    }

    private var updateStatusPresentation: (label: String, color: Color) {
        if updateManager.isChecking {
            return ("Đang kiểm tra", AppTheme.statusInfo)
        }
        if updateManager.updateOffer != nil {
            return ("Có cập nhật", AppTheme.statusInfo)
        }
        if updateManager.hasChecked {
            return ("Mới nhất", AppTheme.statusSuccess)
        }
        return ("Chưa kiểm tra", AppTheme.statusInfo)
    }

    private var remainingTime: String {
        guard let expires = auth.expiresAt else { return "Vĩnh viễn" }
        let interval = expires.timeIntervalSinceNow
        if interval <= 0 { return "Đã hết hạn" }
        let days = Int(interval / 86400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
        if days > 0 { return "\(days) ngày \(hours) giờ" }
        let mins = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        return "\(hours) giờ \(mins) phút"
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "Chưa kích hoạt" }
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        f.locale = Locale(identifier: "vi_VN")
        return f.string(from: date)
    }
}
