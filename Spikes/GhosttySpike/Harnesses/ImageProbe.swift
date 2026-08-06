import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: image-probe <png>\n".utf8))
    exit(64)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let source = CGImageSourceCreateWithURL(url, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("unable to load image\n".utf8))
    exit(1)
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

var buckets = Set<UInt32>()
var lumaTotal = 0.0
var lumaSquaredTotal = 0.0
let stride = max(1, min(width, height) / 300)
var sampleCount = 0

for y in Swift.stride(from: 0, to: height, by: stride) {
    for x in Swift.stride(from: 0, to: width, by: stride) {
        let index = (y * width + x) * 4
        let red = UInt32(pixels[index])
        let green = UInt32(pixels[index + 1])
        let blue = UInt32(pixels[index + 2])
        buckets.insert(((red / 8) << 10) | ((green / 8) << 5) | (blue / 8))
        let luma = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        lumaTotal += luma
        lumaSquaredTotal += luma * luma
        sampleCount += 1
    }
}

let mean = lumaTotal / Double(sampleCount)
let variance = max(0, lumaSquaredTotal / Double(sampleCount) - mean * mean)
print("width=\(width)")
print("height=\(height)")
print("sample_count=\(sampleCount)")
print("quantized_color_count=\(buckets.count)")
print(String(format: "luma_variance=%.3f", variance))

exit(buckets.count >= 16 && variance >= 20 ? 0 : 2)
