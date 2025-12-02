// ImageWriter.swift
// 图像输出工具

import Foundation

/// 图像写入器
class ImageWriter {
    /// 保存为 PPM 图片
    static func savePPM(pixels: [Float], width: Int, height: Int, filename: String) {
        var ppmContent = "P3\n\(width) \(height)\n255\n"

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                var r = pixels[index]
                var g = pixels[index + 1]
                var b = pixels[index + 2]

                // Replace NaN components with zero (防止 Surface Acne)
                // NaN 检测: NaN != NaN
                if r.isNaN { r = 0.0 }
                if g.isNaN { g = 0.0 }
                if b.isNaN { b = 0.0 }

                // Gamma 校正 (gamma = 2)
                let rGamma = sqrt(r)
                let gGamma = sqrt(g)
                let bGamma = sqrt(b)

                // 转换为 0-255
                let ir = UInt8(256 * Swift.min(Swift.max(rGamma, 0), 0.999))
                let ig = UInt8(256 * Swift.min(Swift.max(gGamma, 0), 0.999))
                let ib = UInt8(256 * Swift.min(Swift.max(bGamma, 0), 0.999))

                ppmContent += "\(ir) \(ig) \(ib)\n"
            }
        }

        do {
            try ppmContent.write(toFile: filename, atomically: true, encoding: .utf8)
            print("[Output] ✓ Saved: \(filename)")
        } catch {
            print("[Output] ❌ Failed to save: \(error)")
        }
    }

    /// 对累积的颜色进行平均并应用 Gamma 校正
    static func averageAndSavePPM(accumulatedPixels: inout [Float], samplesPerPixel: UInt32, width: Int, height: Int, filename: String) {
        // 对累积的颜色进行平均
        let totalSamples = Float(samplesPerPixel)
        for i in 0..<(width * height * 4) {
            accumulatedPixels[i] /= totalSamples
        }

        savePPM(pixels: accumulatedPixels, width: width, height: height, filename: filename)
    }
}
