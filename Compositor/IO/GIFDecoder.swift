import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads immutable bytes rather than a live file, so frames survive source deletion and atomic project saves.
nonisolated enum GIFDecoder {
    static func source(_ data: Data, name: String) throws -> GIFSource {
        guard !data.isEmpty, data.count <= GIFSource.byteLimit else { throw ImageImportError.tooLarge }
        return try autoreleasepool {
            guard let reader = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(reader) as String? == UTType.gif.identifier else { throw ImageImportError.unreadable }
            let count = CGImageSourceGetCount(reader)
            guard count > 0 else { throw ImageImportError.unreadable }
            guard count <= GIFTimelineLimits.maxFrames else { throw ImageImportError.tooManyFrames }
            let side = max(1, min(GIFTimelineLimits.thumbnailSide,
                Int(sqrt(Double(GIFTimelineLimits.thumbnailPixelBudget) / Double(count)))))
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
            var frames: [GIFTimelineFrame] = []
            var size = (width: 0, height: 0)
            for index in 0..<count {
                try Task.checkCancellation()
                let dimensions = try frameSize(reader, index: index)
                if index == 0 { size = dimensions }
                // ImageIO's GIF reader returns composed frames on the animation's logical canvas.
                guard dimensions == size else { throw ImageImportError.unreadable }
                let frame = try autoreleasepool { () throws -> GIFTimelineFrame in
                    guard let image = CGImageSourceCreateThumbnailAtIndex(reader, index, options as CFDictionary) else {
                        throw ImageImportError.unreadable
                    }
                    return GIFTimelineFrame(index: index, thumbnail: try PixelAdjust.thumbnail(of: image),
                                            duration: duration(reader, index: index))
                }
                frames.append(frame)
            }
            return GIFSource(data: data, frames: frames, width: size.width, height: size.height)
        }
    }

    static func frame(_ animation: GIFAnimation, index: Int, name: String, reader: CGImageSource? = nil,
                      preview: Bool = false) throws -> ImportedImage {
        guard let sourceIndex = animation.sourceFrameIndex(for: index),
              animation.source.frames.indices.contains(sourceIndex), animation.geometry?.isValid != false else {
            throw ImageImportError.unreadable
        }
        if let edited = animation.framePixels[index] { return edited }
        return try autoreleasepool {
            let reader = try reader ?? Self.reader(animation.source)
            _ = try frameSize(reader, index: sourceIndex)
            guard let decoded = CGImageSourceCreateImageAtIndex(reader, sourceIndex,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ImageImportError.unreadable }
            let image = try raster(decoded, geometry: animation.geometry, keepsDecodedPixels: preview)
            let thumbnail = preview && animation.geometry == nil ? animation.source.frames[sourceIndex].thumbnail
                : try PixelAdjust.thumbnail(of: image)
            return ImportedImage(image: image, thumbnail: thumbnail, name: name)
        }
    }

    static func reader(_ source: GIFSource) throws -> CGImageSource {
        guard let reader = CGImageSourceCreateWithData(source.data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ImageImportError.unreadable }
        return reader
    }

    static func raster(_ decoded: CGImage, geometry: GIFFrameGeometry?, keepsDecodedPixels: Bool) throws -> CGImage {
        let width = geometry?.width ?? decoded.width
        let height = geometry?.height ?? decoded.height
        // Other layouts still need canonical pixels for editing and the canvas's direct texture uploads.
        if keepsDecodedPixels, geometry == nil, decoded.bitsPerComponent == 8, decoded.bitsPerPixel == 32,
           decoded.bytesPerRow == width * 4, decoded.colorSpace == CGColorSpace(name: CGColorSpace.sRGB),
           decoded.bitmapInfo == CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
               | CGBitmapInfo.byteOrder32Big.rawValue), decoded.decode == nil, !decoded.isMask {
            return decoded
        }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        if let geometry {
            // BrushRaster already uses top-left coordinates; only the source image needs a y-up draw space.
            context.concatenate(geometry.unitTransform.concatenating(CGAffineTransform(scaleX: CGFloat(width), y: CGFloat(height))))
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = geometry.sampling.quality
            context.setShouldAntialias(geometry.sampling != .nearest)
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        } else {
            BrushRaster.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        }
        guard let image = context.makeImage() else { throw ImageImportError.unreadable }
        return image
    }

    private static func frameSize(_ reader: CGImageSource, index: Int) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageImportError.unreadable }
        guard width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= DocumentLimits.maxSurfacePixels else { throw ImageImportError.tooLarge }
        return (width, height)
    }

    private static func duration(_ reader: CGImageSource, index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = [gif?[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval,
                     gif?[kCGImagePropertyGIFDelayTime] as? TimeInterval]
            .compactMap { $0 }.first { $0.isFinite && $0 > 0 } ?? GIFTimelineLimits.defaultFrameDuration
        return max(GIFTimelineLimits.minimumFrameDuration, delay)
    }
}

/// One ImageIO reader per playback run, confined to its decoder actor rather than shared mutable source state.
actor GIFPlaybackDecoder {
    private let animation: GIFAnimation
    private let name: String
    private var reader: CGImageSource?

    init(_ animation: GIFAnimation, name: String) {
        self.animation = animation
        self.name = name
    }

    func frame(at index: Int) throws -> GIFPreparedFrame<ImportedImage> {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        if reader == nil { reader = try GIFDecoder.reader(animation.source) }
        guard let reader, let sourceIndex = animation.sourceFrameIndex(for: index),
              animation.source.frames.indices.contains(sourceIndex) else { throw ImageImportError.unreadable }
        // Retain the reader's parsing work, without accumulating decoded images across a long animation.
        let frame = try autoreleasepool {
            defer { CGImageSourceRemoveCacheAtIndex(reader, sourceIndex) }
            return try GIFDecoder.frame(animation, index: index, name: name, reader: reader, preview: true)
        }
        try Task.checkCancellation()
        return GIFPreparedFrame(frame, decodeDuration: started.duration(to: .now))
    }
}
