// Read actual simctl PNGs through CoreGraphics. UIKit drawHierarchy does not
// reliably capture AVPlayerLayer, so the runner captures the simulator display.
import Foundation
import CoreGraphics
import ImageIO

func require(_ value: Bool, _ message: String) {
    guard value else { fputs(message + "\n", stderr); exit(1) }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let reportData = try Data(contentsOf: directory.appendingPathComponent("report.json"))
let report = try JSONSerialization.jsonObject(with: reportData) as! [String: Any]
require(report["result"] as? String == "PASS", "Native playback driver did not pass")
let dimensions = report["screenPoints"] as! [Double]
let captures = report["captures"] as! [String]
var measurements: [[String: Any]] = []

for name in captures {
    let url = directory.appendingPathComponent(name + ".png")
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    }
    func average(centerX: Double, centerY: Double, radius: Double) -> [Double] {
        var sum = [0.0, 0.0, 0.0], count = 0.0
        let scale = Double(image.width) / dimensions[0]
        let cx = Int(Double(image.width) * centerX), cy = Int(Double(image.height) * centerY)
        let extent = Int(radius * scale)
        for y in max(0, cy - extent)..<min(image.height, cy + extent) {
            for x in max(0, cx - extent)..<min(image.width, cx + extent) {
                let offset = (y * image.width + x) * 4
                for channel in 0..<3 { sum[channel] += Double(pixels[offset + channel]) }
                count += 1
            }
        }
        return sum.map { $0 / max(count, 1) }
    }
    let marker = average(centerX: 0.25, centerY: 0.68, radius: 8)
    // Accommodate bitmap row orientation without accepting any unrelated UI:
    // this unique magenta marker exists only on the underlying video plane.
    let mirroredMarker = average(centerX: 0.25, centerY: 0.32, radius: 8)
    let visibleMarker = marker[0] > mirroredMarker[0] ? marker : mirroredMarker
    let background = average(centerX: 0.72, centerY: 0.25, radius: 18)
    if name.hasPrefix("main-") && name != "main-baseline" {
        require(visibleMarker[0] > 180 && visibleMarker[1] < 85 && visibleMarker[2] > 100,
                "Settled NavigationStack obscures the underlying video plane: \(name), RGB \(marker), mirrored \(mirroredMarker)")
    }
    if name.hasPrefix("login-") {
        require(background.reduce(0, +) / 3 > 15,
                "Actual simulator login display is black after loop: \(name), RGB \(background)")
    }
    measurements.append(["capture": name, "markerRGB": marker, "mirroredMarkerRGB": mirroredMarker, "backgroundRGB": background,
                         "pixelDimensions": [image.width, image.height]])
}
let result: [String: Any] = ["result": "PASS", "captureCount": captures.count, "measurements": measurements,
    "scope": "Actual iOS Simulator screen PNGs. Settled navigation marker checks the background plane; login display checks reject black captures. AVFoundation frame/time evidence is in report.json."]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appendingPathComponent("screenshot-verification.json"))
print(String(data: data, encoding: .utf8)!)
