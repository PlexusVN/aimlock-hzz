import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The production cache/transport methods are injected verbatim. UIKit decoding
// is isolated here; bytes beginning with 0 represent an unsupported image.
struct UIImage: Equatable {
    let bytes: Data
    init?(data: Data) {
        guard let first = data.first, first != 0 else { return nil }
        bytes = data
    }
    init?(contentsOfFile path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        self.init(data: data)
    }
}
struct PatchItem { let id: Int; let categoryId: Int; let imageUrl: String }
enum FeatureThumbnailDecoder {
    static func decode(_ data:Data)->UIImage? { UIImage(data:data) }
    static func read(_ url:URL)->UIImage? { UIImage(contentsOfFile:url.path) }
}
struct PatchCategory { let id: Int; let imageUrl: String; var name: String { "Fixture" } }

@MainActor final class ImageTransport {
    var calls: [URL] = []
    var requests: [URLRequest] = []
    var handler: (URL) async throws -> (Data, URLResponse) = { url in
        (Data([1]), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func data(from url: URL) async throws -> (Data, URLResponse) {
        calls.append(url)
        return try await handler(url)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await data(from: request.url!)
    }
}
@MainActor final class ImageService {
    let baseURL = "https://fixture.invalid"
    let pinnedSession = ImageTransport()
    let defaults: UserDefaults
    let patchImagesDir: URL
    let categoryImagesDir: URL
    var patches: [PatchItem] = []
    var categories: [PatchCategory] = []
    var patchImageCache: [Int: UIImage] = [:]
    var categoryImageCache: [Int: UIImage] = [:]
    var patchImageSources: [Int:String] = [:]
    var categoryImageSources: [Int:String] = [:]
    let root: URL
    let suite = "image-tests-" + UUID().uuidString
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        patchImagesDir = root.appendingPathComponent("patches")
        categoryImagesDir = root.appendingPathComponent("categories")
        try FileManager.default.createDirectory(at: patchImagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: categoryImagesDir, withIntermediateDirectories: true)
    }
    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    // PRODUCTION_METHODS
}

@main struct FeatureImagesSelfCheck {
    @MainActor static func main() async throws {
        let s = try ImageService()
        defer { s.clean() }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            assertions += 1
        }
        func reply(_ url: URL, _ byte: UInt8, _ status: Int = 200) -> (Data, URLResponse) {
            (Data([byte]), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let category = PatchCategory(id: 2, imageUrl: "/category.png")
        let first = PatchItem(id: 7, categoryId: 2, imageUrl: "/first.png")
        s.categories = [category]; s.patches = [first]
        check(s.cachedImage(for: first) == nil, "no bundled/fixed image on cold start")
        s.pinnedSession.handler = { reply($0, 2) }
        await s.downloadCategoryImageIfNeeded(category)
        check(s.pinnedSession.calls.last?.absoluteString == "https://fixture.invalid/category.png", "relative URL uses Auth origin")
        check(s.cachedImage(for: first) == nil, "category must not substitute for a feature avatar")
        s.pinnedSession.handler = { reply($0, 3) }
        await s.downloadPatchImageIfNeeded(first)
        check(s.cachedImage(for: first)?.bytes == Data([3]), "own image wins over category")
        let calls = s.pinnedSession.calls.count
        await s.downloadPatchImageIfNeeded(first)
        check(s.pinnedSession.calls.count == calls, "memory cache avoids redundant transfer")
        s.patchImageCache = [:]
        check(s.cachedImage(for: first)?.bytes == Data([3]), "disk cache reload preserves own image")
        s.patchImageCache = [:]
        await s.downloadPatchImageIfNeeded(first)
        check(s.pinnedSession.calls.count == calls, "disk cache avoids redundant transfer")

        s.pinnedSession.handler = { reply($0, 6) }
        await s.downloadPatchImageIfNeeded(first, force: true)
        check(s.cachedImage(for: first)?.bytes == Data([6]), "same URL replacement refreshes uploaded bytes")
        check(s.pinnedSession.requests.last?.cachePolicy == .reloadIgnoringLocalCacheData, "refresh bypasses URL cache")
        check(s.pinnedSession.requests.last?.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "refresh asks intermediaries to revalidate")
        let sibling = PatchItem(id: 8, categoryId: 2, imageUrl: "/sibling.png")
        s.patches = [first, sibling]
        s.pinnedSession.handler = { reply($0, 8) }
        await s.downloadPatchImageIfNeeded(sibling)
        check(s.cachedImage(for: sibling)?.bytes == Data([8]), "same-category feature uses its own image")
        check(s.cachedImage(for: first)?.bytes == Data([6]), "another feature image does not replace first avatar")

        let changed = PatchItem(id: 7, categoryId: 2, imageUrl: "https://fixture.invalid/changed.png")
        s.patches = [changed]
        check(s.cachedImage(for: changed) == nil, "changed URL cannot display another image")
        s.pinnedSession.handler = { reply($0, 4) }
        await s.downloadPatchImageIfNeeded(changed)
        check(s.cachedImage(for: changed)?.bytes == Data([4]), "changed image replaces cache")
        let removed = PatchItem(id: 7, categoryId: 2, imageUrl: "")
        s.patches = [removed]
        check(s.cachedImage(for: removed) == nil, "removed own image never returns category fallback")
        let removedCategory = PatchCategory(id: 2, imageUrl: "")
        s.categories = [removedCategory]
        check(s.cachedImage(for: removed) == nil, "removed category image cannot resurrect disk cache")
        let beforeEmpty = s.pinnedSession.calls.count
        await s.downloadPatchImageIfNeeded(removed)
        await s.downloadCategoryImageIfNeeded(removedCategory)
        check(s.pinnedSession.calls.count == beforeEmpty, "empty URLs do not send requests")

        s.categories = [category]; s.patches = [first]
        for status in [404, 500] {
            s.pinnedSession.handler = { reply($0, 8, status) }
            await s.downloadPatchImageIfNeeded(first, force: true)
            check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "HTTP failure cannot publish image")
        }
        s.pinnedSession.handler = { reply($0, 0) }
        await s.downloadPatchImageIfNeeded(first, force: true)
        check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "invalid image cannot publish cache")
        s.pinnedSession.handler = { _ in throw URLError(.timedOut) }
        await s.downloadPatchImageIfNeeded(first, force: true)
        check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "timeout cannot change URL binding")

        var pending: CheckedContinuation<(Data, URLResponse), Never>?
        s.pinnedSession.handler = { _ in await withCheckedContinuation { pending = $0 } }
        let stale = Task { @MainActor in await s.downloadPatchImageIfNeeded(first, force: true) }
        while pending == nil { await Task.yield() }
        s.patches = [changed]
        pending!.resume(returning: reply(URL(string: "https://fixture.invalid/first.png")!, 9))
        await stale.value
        check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "old response cannot overwrite newer catalog")
        pending = nil; s.patches = [first]
        let cancelled = Task { @MainActor in await s.downloadPatchImageIfNeeded(first, force: true) }
        while pending == nil { await Task.yield() }
        cancelled.cancel()
        pending!.resume(returning: reply(URL(string: "https://fixture.invalid/first.png")!, 9))
        await cancelled.value
        check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "cancelled transfer cannot update cache")

        pending = nil
        let deleted = Task { @MainActor in await s.downloadPatchImageIfNeeded(first, force: true) }
        while pending == nil { await Task.yield() }
        s.patches = []
        pending!.resume(returning: reply(URL(string: "https://fixture.invalid/first.png")!, 9))
        await deleted.value
        check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "removed patch cannot publish a late image")

        let categoryChanged = PatchCategory(id: 2, imageUrl: "/category-new.png")
        s.categories = [categoryChanged]
        check(s.categoryImage(for: 2) == nil, "changed category cannot show old bytes")
        s.pinnedSession.handler = { reply($0, 6) }
        await s.downloadCategoryImageIfNeeded(categoryChanged)
        check(s.categoryImage(for: 2)?.bytes == Data([6]), "category replacement displayed")
        s.categoryImageCache = [:]
        check(s.categoryImage(for: 2)?.bytes == Data([6]), "category disk reload")
        let beforeCategoryCache = s.pinnedSession.calls.count
        await s.downloadCategoryImageIfNeeded(categoryChanged)
        check(s.pinnedSession.calls.count == beforeCategoryCache, "unchanged category reuses cache")
        pending = nil
        s.pinnedSession.handler = { _ in await withCheckedContinuation { pending = $0 } }
        let staleCategory = Task { @MainActor in await s.downloadCategoryImageIfNeeded(category, force: true) }
        while pending == nil { await Task.yield() }
        pending!.resume(returning: reply(URL(string: "https://fixture.invalid/category.png")!, 9))
        await staleCategory.value
        check(s.categoryImage(for: 2)?.bytes == Data([6]), "late category response cannot replace current image")
        pending = nil
        let cancelledCategory = Task { @MainActor in await s.downloadCategoryImageIfNeeded(categoryChanged, force: true) }
        while pending == nil { await Task.yield() }
        cancelledCategory.cancel()
        pending!.resume(returning: reply(URL(string: "https://fixture.invalid/category-new.png")!, 9))
        await cancelledCategory.value
        check(s.categoryImage(for: 2)?.bytes == Data([6]), "cancelled category response ignored")

        // Corrupt disk bytes under a matching URL trigger a new download.
        s.patches = [changed]; s.patchImageCache = [:]
        try Data([0]).write(to: s.patchImagesDir.appendingPathComponent("patch_7.jpg"))
        s.pinnedSession.handler = { reply($0, 7) }
        let beforeCorrupt = s.pinnedSession.calls.count
        await s.downloadPatchImageIfNeeded(changed)
        check(s.pinnedSession.calls.count == beforeCorrupt + 1, "invalid disk image refetched")
        check(s.cachedImage(for: changed)?.bytes == Data([7]), "invalid disk bytes replaced")

        // A failed atomic write must not bind previous disk bytes to a new URL.
        try FileManager.default.removeItem(at: s.patchImagesDir)
        s.patches = [first]
        s.pinnedSession.handler = { reply($0, 5) }
        await s.downloadPatchImageIfNeeded(first, force: true)
        check(s.defaults.string(forKey: "patch_img_url_7") == changed.imageUrl, "disk failure keeps URL binding unchanged")
        try FileManager.default.removeItem(at: s.categoryImagesDir)
        s.categories = [category]
        await s.downloadCategoryImageIfNeeded(category, force: true)
        check(s.defaults.string(forKey: "cat_img_url_2") == categoryChanged.imageUrl, "category disk failure keeps old URL binding")
        print("Feature images: \(assertions) behavior assertions passed")
    }
}
