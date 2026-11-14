import SwiftUI

private func userFacingFeatureText(_ raw: String, fallback: String) -> String {
    let hiddenTerms = [".3105", "3105", "patch", "file", "tệp"]
    let cleaned = hiddenTerms.reduce(raw) { value, term in
        value.replacingOccurrences(of: term, with: "", options: .caseInsensitive)
    }
    let normalized = cleaned
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return normalized.isEmpty ? fallback : normalized
}

struct FeaturesView: View {
    var showSystemDashboard: Binding<Bool>? = nil
    @EnvironmentObject private var service: FeaturePatchService
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var protectedDownloads = ProtectedDownloadService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCategoryID: Int?
    @State private var showCategoryPicker = false
    @State private var activeToast: ToastInfo?
    @State private var contentVisible = false

    var body: some View {
        NavigationStack {
            ZStack {
                GamingBackdrop()

                ScrollView {
                    VStack(spacing: 16) {
                        categoryPanel
                        patchPanel
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible || reduceMotion ? 0 : 10)
                    .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.28), value: contentVisible)
                }
            }
            .appVideoNavigationSurface()
            .navigationTitle("Chức năng")
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.gamingBlueBright)
            .toolbar {
                if let showSystemDashboard = showSystemDashboard {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            Haptics.soft()
                            showSystemDashboard.wrappedValue = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(AppTheme.gamingBlueBright)
                                .frame(width: 32, height: 32)
                                .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
                        }
                    }
                }
            }
            .refreshable { await service.syncFromServer(auth: authManager) }
            .onAppear {
                if selectedCategoryID == nil, let first = service.categories.first {
                    selectedCategoryID = first.id
                }
                service.preloadCategoryImages()
                withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.28)) {
                    contentVisible = true
                }
            }
            .onChange(of: service.categories, perform: { categories in
                if selectedCategoryID == nil, let first = categories.first {
                    selectedCategoryID = first.id
                }
                service.preloadCategoryImages()
            })
        }
        .glassToast(toast: $activeToast)
        .overlay {
            if showCategoryPicker {
                ZStack {
                    Color.black.opacity(0.82)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                showCategoryPicker = false
                            }
                        }

                    customCategoryPicker
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                .zIndex(100)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Category selection

    private var categoryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("DANH MỤC")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                Spacer()
                Text(String(format: "%02d", service.categories.count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(AppTheme.gamingTextSecondary)

            if service.categories.isEmpty {
                HStack(spacing: 10) {
                    if protectedDownloads.accessNotice == nil {
                        ProgressView().tint(AppTheme.gamingText)
                    } else {
                        AimlockReticleIcon().frame(width: 24, height: 24)
                    }
                    Text(protectedDownloads.accessNotice ?? "Đang chuẩn bị...")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                categorySelect
            }
        }
        .padding(14)
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
    }

    private var categorySelect: some View {
        Button {
            Haptics.soft()
            withAnimation(AppTheme.gamingTabSpring) {
                showCategoryPicker = true
            }
        } label: {
            HStack(spacing: 12) {
                if let category = selectedCategory {
                    categoryArtwork(category, size: 44)
                } else {
                    AimlockReticleIcon()
                        .frame(width: 24, height: 24)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.gamingSurfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedCategory.map { userFacingFeatureText($0.name, fallback: "Danh mục") } ?? "Chọn danh mục")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.gamingText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if selectedCategory != nil {
                        Text("\(filteredPatches.count) chức năng")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.gamingTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.gamingText)
                    .rotationEffect(.degrees(showCategoryPicker ? 180 : 0))
                    .frame(width: 28, height: 28)
                    .background(AppTheme.gamingSurfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(12)
            .background(AppTheme.gamingBackgroundRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.gamingBorder.opacity(0.75), lineWidth: 1))
        }
        .buttonStyle(GamingPressButtonStyle(scale: 0.985))
        .accessibilityLabel("Chọn danh mục")
    }

    private var selectedCategory: PatchCategory? {
        guard let id = selectedCategoryID else { return nil }
        return service.categories.first { $0.id == id }
    }

    @ViewBuilder
    private func categoryArtwork(_ category: PatchCategory, size: CGFloat) -> some View {
        ZStack {
            AppTheme.gamingSurfaceRaised
            if let uiImage = service.categoryImage(for: category.id) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if !category.imageUrl.isEmpty, let url = URL(string: category.imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        Image(systemName: category.icon.isEmpty ? "gamecontroller.fill" : category.icon)
                            .font(.system(size: size * 0.43, weight: .semibold))
                            .foregroundStyle(AppTheme.gamingText)
                    }
                }
            } else {
                Image(systemName: category.icon.isEmpty ? "gamecontroller.fill" : category.icon)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(AppTheme.gamingText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var customCategoryPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chọn danh mục").font(.system(size: 17, weight: .bold))
                    Text("\(service.categories.count) danh mục")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                }
                Spacer()
            }
            .foregroundStyle(AppTheme.gamingText)
            .padding(18)

            Divider().overlay(AppTheme.gamingBorder)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(service.categories) { cat in
                        Button {
                            Haptics.selection()
                            withAnimation(AppTheme.gamingTabSpring) {
                                selectedCategoryID = cat.id
                                showCategoryPicker = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                categoryArtwork(cat, size: 42)
                                Text(userFacingFeatureText(cat.name, fallback: "Danh mục"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppTheme.gamingText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if selectedCategoryID == cat.id {
                                    AimlockReticleIcon().frame(width: 22, height: 22)
                                        .foregroundStyle(AppTheme.gamingText)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AppTheme.gamingTextSecondary)
                                }
                            }
                            .padding(12)
                            .background(selectedCategoryID == cat.id ? AppTheme.gamingSurfaceRaised : AppTheme.gamingBackgroundRaised,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selectedCategoryID == cat.id ? AppTheme.grey400 : AppTheme.gamingBorder, lineWidth: 1))
                        }
                        .buttonStyle(GamingPressButtonStyle(scale: 0.985))
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 350)

            Divider().overlay(AppTheme.gamingBorder)
            Button {
                Haptics.soft()
                withAnimation(AppTheme.gamingTabSpring) { showCategoryPicker = false }
            } label: {
                Text("Hủy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.gamingTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.grey400.opacity(0.6), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.35), radius: 24, y: 12)
        .padding(.horizontal, 24)
    }

    // MARK: - Functions

    private var patchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                AimlockReticleIcon().frame(width: 20, height: 20)
                    .foregroundStyle(AppTheme.gamingText)
                Text("Chức năng")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppTheme.gamingText)
                Spacer()
                Text(String(format: "%02d", filteredPatches.count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.gamingTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
            }
            .padding(.horizontal, 2)

            if service.isLoading && service.patches.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.gamingText)
                    Text("Đang chuẩn bị chức năng...")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.gamingTextSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if filteredPatches.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredPatches, id: \.downloadIdentity) { patch in
                        PatchCardView(patch: patch, service: service, auth: authManager, activeToast: $activeToast)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            AimlockReticleIcon().frame(width: 34, height: 34)
                .foregroundStyle(AppTheme.grey400)
            Text(service.catalogError == nil ? "Chưa có chức năng nào" : "Không thể tải danh sách chức năng")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.gamingText)
            Text(service.catalogError ?? "Đang chuẩn bị chức năng...")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.gamingTextSecondary)
                .multilineTextAlignment(.center)
            if service.catalogError != nil {
                Button("Thử tải lại") {
                    Task { await service.syncFromServer(auth: authManager) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.gamingText)
                .disabled(service.isLoading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))
    }

    private var filteredPatches: [PatchItem] {
        if let catID = selectedCategoryID {
            return service.patches.filter { $0.categoryId == catID }
        }
        return service.patches
    }
}

// MARK: - Function card

struct PatchCardView: View {
    let patch: PatchItem
    @ObservedObject var service: FeaturePatchService
    @ObservedObject var auth: AuthManager
    private var applicationState: PatchApplicationState { service.patchApplicationState(patch) }
    private var isApplied: Bool { applicationState.requiresRestore }
    @State private var isWorking = false
    @Binding var activeToast: ToastInfo?

    private var stateColor: Color {
        applicationState == .recoveryRequired ? AppTheme.statusWarning : (isApplied ? AppTheme.statusSuccess : AppTheme.gamingTextSecondary)
    }
    private var stateCode: String {
        applicationState == .recoveryRequired ? "RST" : (isApplied ? "ON" : "OFF")
    }

    var body: some View {
        HStack(spacing: 12) {
            patchImage
            VStack(alignment: .leading, spacing: 7) {
                Text(userFacingFeatureText(patch.name, fallback: "Chức năng"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.gamingText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(stateCode)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(stateColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(applicationState == .recoveryRequired ? "Cần khôi phục" : (isApplied ? "Chức năng đang bật" : "Sẵn sàng"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(stateColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toggleButton
        }
        .padding(14)
        .background(AppTheme.gamingSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isApplied ? stateColor.opacity(0.45) : AppTheme.gamingBorder, lineWidth: 1))
        .overlay(alignment: .leading) {
            if isApplied {
                RoundedRectangle(cornerRadius: 1)
                    .fill(stateColor)
                    .frame(width: 2)
                    .padding(.vertical, 17)
            }
        }
    }

    @ViewBuilder
    private var patchImage: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let uiImage = service.cachedImage(for: patch) ?? service.categoryImage(for: patch.categoryId) {
                    Image(uiImage: uiImage).resizable().scaledToFill()
                } else {
                    ZStack {
                        AppTheme.gamingBackgroundRaised
                        AimlockReticleIcon().frame(width: 25, height: 25)
                            .foregroundStyle(AppTheme.gamingText)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.gamingBorder, lineWidth: 1))

            AimlockReticleIcon()
                .frame(width: 10, height: 10)
                .foregroundStyle(AppTheme.gamingBackground)
                .frame(width: 16, height: 16)
                .background(AppTheme.gamingText, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .offset(x: 4, y: 4)
        }
        .frame(width: 48, height: 48, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var toggleButton: some View {
        if isWorking {
            ZStack {
                Capsule().fill(AppTheme.gamingSurfaceRaised)
                    .frame(width: 52, height: 28)
                    .overlay(Capsule().stroke(AppTheme.gamingBorder, lineWidth: 1))
                ProgressView().tint(AppTheme.gamingText).scaleEffect(0.8)
            }
            .frame(width: 56, height: 44)
            .accessibilityLabel("Đang xử lý")
        } else {
            Button(action: { togglePatch() }) {
                ZStack {
                    Capsule()
                        .fill(isApplied ? AppTheme.gamingText : AppTheme.gamingSurfaceRaised)
                        .frame(width: 52, height: 28)
                        .overlay(Capsule().stroke(isApplied ? AppTheme.gamingText : AppTheme.grey400.opacity(0.45), lineWidth: 1))
                    Circle()
                        .fill(isApplied ? AppTheme.gamingBackground : AppTheme.gamingText)
                        .frame(width: 22, height: 22)
                        .offset(x: isApplied ? 11 : -11)
                    if isApplied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(AppTheme.gamingText)
                            .offset(x: 11)
                    }
                }
                .frame(width: 56, height: 44)
                .contentShape(Rectangle())
                .animation(AppTheme.gamingTabSpring, value: isApplied)
            }
            .buttonStyle(GamingPressButtonStyle(scale: 0.97))
            .accessibilityLabel(userFacingFeatureText(patch.name, fallback: "Chức năng"))
            .accessibilityValue(applicationState == .recoveryRequired ? "Cần khôi phục" : (isApplied ? "Đang bật" : "Đang tắt"))
            .accessibilityHint(isApplied ? "Chạm để tắt và khôi phục" : "Chạm để bật")
        }
    }

    // MARK: - Actions

    private func togglePatch() {
        Haptics.medium()
        isWorking = true
        activeToast = ToastInfo(
            title: isApplied ? "Chức năng đang tắt" : "Chức năng đang bật",
            message: "Vui lòng chờ...",
            isSuccess: true
        )

        let targetIsApplied = isApplied
        Task.detached(priority: .userInitiated) {
            if targetIsApplied {
                do {
                    try await service.restorePatch(patch, auth: auth)
                    await MainActor.run {
                        isWorking = false
                        Haptics.success()
                        activeToast = ToastInfo(
                            title: "Tắt chức năng thành công",
                            message: "Đã khôi phục dữ liệu đã sao lưu trước lần áp dụng này.",
                            isSuccess: true
                        )
                    }
                } catch {
                    await MainActor.run {
                        isWorking = false
                        Haptics.error()
                        activeToast = ToastInfo(
                            title: "Không thể tắt chức năng",
                            message: (error as? LocalizedError)?.errorDescription
                                ?? "Không thể khôi phục dữ liệu (mã \((error as NSError).code)).",
                            isSuccess: false
                        )
                    }
                }
            } else {
                do {
                    try await service.applyPatch(patch, auth: auth)
                    await MainActor.run {
                        isWorking = false
                        Haptics.success()
                        activeToast = ToastInfo(
                            title: "Bật chức năng thành công",
                            message: "Chức năng đang bật.",
                            isSuccess: true
                        )
                    }
                } catch {
                    await MainActor.run {
                        isWorking = false
                        Haptics.error()
                        activeToast = ToastInfo(
                            title: "Không thể bật chức năng",
                            message: (error as? LocalizedError)?.errorDescription
                                ?? "Không thể hoàn tất thao tác (mã \((error as NSError).code)).",
                            isSuccess: false
                        )
                    }
                }
            }
        }
    }

}
