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
    @State private var workingActionID: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var pendingRestore: FeatureRestoreReview?

    private var actionsBlocked: Bool {
        workingActionID != nil || service.patchOperationInProgress || pendingRestore != nil
    }

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
                service.refreshRecoveryItems()
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
        .sheet(item: $pendingRestore) { review in
            RestoreReviewSheet(review: review,
                               canConfirm: !service.patchOperationInProgress,
                               onCancel: { pendingRestore = nil },
                               onConfirm: { confirmRestore(review) })
        }
        .onChange(of: authManager.authenticationRevision) { _ in
            // A confirmation and queued UI intent belong to the requesting
            // session. The service independently validates its revision/token.
            pendingRestore = nil
            actionTask?.cancel()
        }
        .onDisappear {
            actionTask?.cancel()
            pendingRestore = nil
        }
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
                        PatchCardView(patch: patch, service: service,
                                      isWorking: workingActionID == "patch:\(patch.downloadIdentity)",
                                      actionsBlocked: actionsBlocked,
                                      onToggle: { togglePatch(patch) })
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

    // All cards share one UI operation state. Changing category can replace a
    // card, but it cannot recreate an enabled button while its write is active.
    private func togglePatch(_ patch: PatchItem) {
        guard !actionsBlocked else { return }
        if service.isPatchEnabled(patch) {
            beginRestore(.patch(patch))
            return
        }
        Haptics.medium()
        let requestedRevision = authManager.authenticationRevision
        workingActionID = "patch:\(patch.downloadIdentity)"
        actionTask = Task { @MainActor in
            defer { workingActionID = nil; actionTask = nil }
            do {
                try await service.applyPatch(patch, auth: authManager)
                showSuccess(title: "Bật chức năng thành công", message: "Chức năng đang bật.")
            } catch {
                if PatchRestoreError.requiresRestoreReview(error), !Task.isCancelled,
                   authManager.authenticationRevision == requestedRevision {
                    do {
                        let confirmation = try await service.inspectPatchRestore(patch, auth: authManager)
                        try Task.checkCancellation()
                        guard authManager.authenticationRevision == requestedRevision else { return }
                        if !confirmation.changedPaths.isEmpty {
                            // Reuse the existing review sheet from this same
                            // toggle. No separate recovery panel is required.
                            pendingRestore = FeatureRestoreReview(target: .patch(patch),
                                confirmation: confirmation, requestedRevision: requestedRevision,
                                reenablePatch: patch)
                            return
                        }
                    } catch {
                        showFailure(error, title: "Không thể bật chức năng")
                        return
                    }
                }
                showFailure(error, title: "Không thể bật chức năng")
            }
        }
    }

    private func beginRestore(_ target: FeatureRestoreTarget) {
        guard !actionsBlocked else { return }
        Haptics.medium()
        let requestedRevision = authManager.authenticationRevision
        workingActionID = target.actionID
        actionTask = Task { @MainActor in
            defer { workingActionID = nil; actionTask = nil }
            do {
                let confirmation: PatchRestoreConfirmation
                switch target {
                case .patch(let patch):
                    confirmation = try await service.inspectPatchRestore(patch, auth: authManager)
                case .recovery(let item):
                    confirmation = try await service.inspectRecoveryRestore(item, auth: authManager)
                }
                try Task.checkCancellation()
                if confirmation.changedPaths.isEmpty {
                    try await restore(target, confirmation: confirmation)
                    showRestoreSuccess()
                } else {
                    pendingRestore = FeatureRestoreReview(target: target, confirmation: confirmation,
                                                          requestedRevision: requestedRevision)
                }
            } catch {
                if !(error is CancellationError) { recordOffFailure(target, requestedRevision: requestedRevision) }
                showFailure(error, title: "Không thể khôi phục")
            }
        }
    }

    private func confirmRestore(_ review: FeatureRestoreReview) {
        guard workingActionID == nil, !service.patchOperationInProgress,
              pendingRestore?.id == review.id else { return }
        pendingRestore = nil
        workingActionID = review.target.actionID
        actionTask = Task { @MainActor in
            defer { workingActionID = nil; actionTask = nil }
            do {
                // The service binds this review to receipt, authentication and
                // inspected bytes; a later change requires another inspection.
                if let patch = review.reenablePatch {
                    try await service.applyPatch(patch, auth: authManager,
                                                 recoveryConfirmation: review.confirmation)
                    showSuccess(title: "Bật chức năng thành công", message: "Chức năng đang bật.")
                } else {
                    try await restore(review.target, confirmation: review.confirmation)
                    showRestoreSuccess()
                }
            } catch {
                if !(error is CancellationError) { recordOffFailure(review.target, requestedRevision: review.requestedRevision) }
                showFailure(error, title: "Chưa thể khôi phục")
            }
        }
    }

    private func recordOffFailure(_ target: FeatureRestoreTarget, requestedRevision: UInt64) {
        guard !Task.isCancelled, authManager.authenticationRevision == requestedRevision else { return }
        switch target {
        case .patch(let patch):
            service.recordPatchOffFailure(patch, requestedRevision: requestedRevision, auth: authManager)
        case .recovery(let item):
            service.recordRecoveryOffFailure(item, requestedRevision: requestedRevision, auth: authManager)
        }
    }

    @MainActor
    private func restore(_ target: FeatureRestoreTarget, confirmation: PatchRestoreConfirmation) async throws {
        switch target {
        case .patch(let patch):
            try await service.restorePatch(patch, auth: authManager, confirmation: confirmation)
        case .recovery(let item):
            try await service.restoreRecovery(item, auth: authManager, confirmation: confirmation)
        }
    }

    private func showRestoreSuccess() {
        showSuccess(title: "Khôi phục thành công", message: "Đã trả lại dữ liệu đã sao lưu trước lần áp dụng này.")
    }

    private func showSuccess(title: String, message: String) {
        Haptics.success()
        activeToast = ToastInfo(title: title, message: message, isSuccess: true)
    }

    private func showFailure(_ error: Error, title: String) {
        guard !(error is CancellationError) else { return }
        Haptics.error()
        activeToast = ToastInfo(title: title,
                              message: (error as? LocalizedError)?.errorDescription
                                ?? "Thao tác chưa hoàn tất. Bản sao lưu được giữ nguyên.",
                              isSuccess: false)
    }
}

private enum FeatureRestoreTarget {
    case patch(PatchItem)
    case recovery(PatchRecoveryItem)

    var actionID: String {
        switch self {
        case .patch(let patch): return "patch:\(patch.downloadIdentity)"
        case .recovery(let item): return "recovery:\(item.projectID.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .patch(let patch): return patch.name
        case .recovery(let item): return item.title
        }
    }
}

private struct FeatureRestoreReview: Identifiable {
    let target: FeatureRestoreTarget
    let confirmation: PatchRestoreConfirmation
    let requestedRevision: UInt64
    var reenablePatch: PatchItem? = nil
    var id: UUID { confirmation.id }
}

private struct RestoreReviewSheet: View {
    let review: FeatureRestoreReview
    let canConfirm: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.statusWarning)
                Text("Dữ liệu đã thay đổi")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.gamingText)
            }
            Text(userFacingFeatureText(review.target.title, fallback: "Chức năng đã áp dụng"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.gamingText)
            Text("Game hoặc ứng dụng đã sửa các mục dưới đây sau lần bật. Khôi phục sẽ thay thế dữ liệu hiện tại bằng bản sao lưu trước lần áp dụng; các thay đổi mới hơn ở những mục này sẽ mất.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.gamingTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(review.confirmation.changedPaths.enumerated()), id: \.offset) { index, path in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .foregroundStyle(AppTheme.gamingTextSecondary)
                            Text(path)
                                .foregroundStyle(AppTheme.gamingText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.gamingBackgroundRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(role: .destructive, action: onConfirm) {
                Text(review.reenablePatch == nil ? "Khôi phục bản sao lưu" : "Khôi phục và bật lại")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(AppTheme.gamingBackground)
                    .background(AppTheme.statusWarning, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(GamingPressButtonStyle(scale: 0.985))
            .disabled(!canConfirm)
            .opacity(canConfirm ? 1 : 0.5)
            .accessibilityHint("Thay thế các mục đã liệt kê bằng dữ liệu đã sao lưu")
            .accessibilityIdentifier("restore-confirm")

            Button("Hủy, giữ dữ liệu hiện tại", action: onCancel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.gamingText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("restore-cancel")
        }
        .padding(20)
        .background(AppTheme.gamingSurface.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Function card

struct PatchCardView: View {
    let patch: PatchItem
    @ObservedObject var service: FeaturePatchService
    let isWorking: Bool
    let actionsBlocked: Bool
    let onToggle: () -> Void
    private var applicationState: PatchApplicationState { service.patchApplicationState(patch) }
    private var isEnabled: Bool { service.isPatchEnabled(patch) }
    private var needsRecovery: Bool { applicationState.requiresRestore && !isEnabled }

    private var stateColor: Color {
        needsRecovery || applicationState == .recoveryRequired ? AppTheme.statusWarning : (isEnabled ? AppTheme.statusSuccess : AppTheme.gamingTextSecondary)
    }
    private var stateCode: String {
        isEnabled ? "ON" : "OFF"
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
                    Text(needsRecovery ? "Chưa khôi phục" : (applicationState == .recoveryRequired ? "Cần khôi phục" : (isEnabled ? "Chức năng đang bật" : "Sẵn sàng")))
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
            .stroke(applicationState.requiresRestore || isEnabled ? stateColor.opacity(0.45) : AppTheme.gamingBorder, lineWidth: 1))
        .overlay(alignment: .leading) {
            if applicationState.requiresRestore || isEnabled {
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
            Button(action: onToggle) {
                ZStack {
                    Capsule()
                        .fill(isEnabled ? AppTheme.gamingText : AppTheme.gamingSurfaceRaised)
                        .frame(width: 52, height: 28)
                        .overlay(Capsule().stroke(isEnabled ? AppTheme.gamingText : AppTheme.grey400.opacity(0.45), lineWidth: 1))
                    Circle()
                        .fill(isEnabled ? AppTheme.gamingBackground : AppTheme.gamingText)
                        .frame(width: 22, height: 22)
                        .offset(x: isEnabled ? 11 : -11)
                    if isEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(AppTheme.gamingText)
                            .offset(x: 11)
                    }
                }
                .frame(width: 56, height: 44)
                .contentShape(Rectangle())
                .animation(AppTheme.gamingTabSpring, value: isEnabled)
            }
            .buttonStyle(GamingPressButtonStyle(scale: 0.97))
            .disabled(actionsBlocked)
            .opacity(actionsBlocked ? 0.5 : 1)
            .accessibilityLabel(userFacingFeatureText(patch.name, fallback: "Chức năng"))
            .accessibilityValue(needsRecovery ? "Đang tắt, chưa khôi phục dữ liệu" : (isEnabled ? "Đang bật" : "Đang tắt"))
            .accessibilityHint(isEnabled ? "Chạm để tắt và khôi phục" : "Chạm để bật")
            .accessibilityIdentifier("patch-toggle-\(patch.downloadIdentity)")
        }
    }

}
