"""Exercise the actual toggle-to-review call graph with actual catalog bodies."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function
from test_catalog_recovery import production_sources

ROOT = Path(__file__).resolve().parents[1]


def toggle_sources():
    ui = (ROOT / 'ThreeOneOSFive/views/FeaturesView.swift').read_text(encoding='utf-8')
    code = production_sources()
    # Add a fault only at the existing OS/native preparation fixture boundary.
    # Catalog apply/recovery catches and cancellation classification stay exact.
    fixture_prepare = extract_function(code, 'static func prepareContainers(receipt:')
    code = code.replace(fixture_prepare, '''static func prepareContainers(receipt:PatchTransactionReceipt)async throws->[String:URL] {
        try ToggleRecoveryBoundary.prepareReceipt()
        return [:]
    }''', 1)
    code += '''
@MainActor enum ToggleRecoveryBoundary {
    static var receiptPreparationError: Error?
    static var receiptPreparationCalls = 0
    static func prepareReceipt() throws {
        receiptPreparationCalls += 1
        if let receiptPreparationError { throw receiptPreparationError }
    }
}
// Reference storage models SwiftUI State capture semantics; it supplies no
// patch/restore decisions. All UI action bodies below are production source.
final class ToggleStateBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
@propertyWrapper struct ToggleState<Value> {
    private let box: ToggleStateBox<Value>
    init(wrappedValue: Value) { box = ToggleStateBox(wrappedValue) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
}
enum Haptics {
    static func medium() {}
    static func success() {}
    static func error() {}
}
struct ToastInfo {
    let title: String
    let message: String
    let isSuccess: Bool
}
'''
    code += extract_function(ui, 'private enum FeatureRestoreTarget {').replace('private enum', 'enum') + '\n'
    code += extract_function(ui, 'private struct FeatureRestoreReview:').replace('private struct', 'struct') + '\n'
    code += '''
@MainActor struct ToggleRecoveryHarness {
    let service: FeaturePatchService
    let authManager: AuthManager
    @ToggleState private var workingActionID: String? = nil
    @ToggleState private var actionTask: Task<Void, Never>? = nil
    @ToggleState private var pendingRestore: FeatureRestoreReview? = nil
    @ToggleState private var activeToast: ToastInfo? = nil
    private var actionsBlocked: Bool {
        workingActionID != nil || service.patchOperationInProgress || pendingRestore != nil
    }
    func tap(_ patch: PatchItem) { togglePatch(patch) }
    func awaitAction() async { await actionTask?.value }
    var review: FeatureRestoreReview? { pendingRestore }
    var toast: ToastInfo? { activeToast }
    func cancelReview() { pendingRestore = nil }
    func confirmReview() { if let review = pendingRestore { confirmRestore(review) } }
    func showFixtureFailure(_ error: Error) { showFailure(error, title: "Không thể bật chức năng") }
}
extension ToggleRecoveryHarness {
'''
    for signature in [
        'private func togglePatch(', 'private func beginRestore(',
        'private func confirmRestore(', 'private func recordOffFailure(',
        'private func restore(', 'private func showRestoreSuccess(',
        'private func showSuccess(', 'private func showFailure(',
    ]:
        code += extract_function(ui, signature) + '\n'
    return code + '}\n'


class ToggleRecoveryFlow(unittest.TestCase):
    def test_actual_toggle_reaches_existing_restore_review(self):
        compiler = shutil.which('swiftc')
        distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
        if compiler:
            command, translate = [compiler], str
            execute = lambda binary: [str(binary)]
        elif os.name == 'nt' and distro:
            compiler = subprocess.check_output(
                ['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
            command = ['wsl', '-d', distro, '--', compiler]
            def translate(value):
                value = str(Path(value).resolve()).replace('\\', '/')
                return '/mnt/' + value[0].lower() + value[2:]
            execute = lambda binary: ['wsl', '-d', distro, '--', translate(binary)]
        else:
            self.skipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')
        code = toggle_sources()
        if os.name == 'nt' and distro:
            # Linux fixtures have no iOS File Protection option. No production
            # state/transaction decision is replaced.
            code = code.replace('.completeFileProtection', '.atomic')
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source, binary = folder / 'ActualToggleRecovery.swift', folder / 'toggle-recovery'
            source.write_text(code, encoding='utf-8')
            subprocess.run(command + ['-swift-version', '5', translate(source),
                translate(ROOT / 'Tests/ToggleRecoveryFlowSelfCheck.swift'), '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)


if __name__ == '__main__':
    unittest.main()
