import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct GIFDecoderTests {
    /// Transparent partial frames with keep, restore-background, and restore-previous disposal.
    private func animation() throws -> GIFAnimation {
        let encoded = "R0lGODlhEAAMAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFBAAAACwAAAAAEAAMAAAIIwADCAwAoKDBgwUHEkTIUCHDhgMfInQosaLFixgzatzIcWNAACH5BAkEAAAALAAAAAAGAAYAgQAAAAD/AAAAAAAAAAgVAAEIHCgwgMEABQ8mNLgQIYCDAQICACH5BA0EAAAALAQAAgAEAAUAgQAAAAAA/wAAAAAAAAgJAAMIHEiwYMGAACH5BAUEAAAALAQAAAAGAAcAgQAAAP//AAAAAAAAAAgXAAEACEAwgMCCBgcWPLhQIUGBECNCDAgAIfkECQQAAAAsBgAAAAYABgCBAAAA/wAAAAAAAAAACBUAAQgcKDCAwQAFDyY0uBAhgIMBAgIAIfkEBQQAAAAsCgACAAQABQCBAAAAAP8AAAAAAAAACAkAAwgcSLBgwYAAOw=="
        return GIFAnimation(source: try GIFDecoder.source(try #require(Data(base64Encoded: encoded)), name: "Disposal"))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try BrushRaster.copy(image)
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }

    @Test func reusedReaderPreservesDisposalAcrossSkipsBacktrackingAndLoops() async throws {
        let animation = try animation()
        let decoder = GIFPlaybackDecoder(animation, name: "Disposal")
        var retained: [(CGImage, Data)] = []
        for index in [0, 1, 2, 3, 4, 5, 0, 4, 1, 5, 2, 0] {
            let expected = try GIFDecoder.frame(animation, index: index, name: "Disposal")
            let actual = try await decoder.frame(at: index).frame
            let bytes = try pixels(expected.image)
            #expect(try pixels(actual.image) == bytes)
            #expect(actual.thumbnail === animation.source.frames[index].thumbnail)
            #expect(actual.image.colorSpace?.name == CGColorSpace.sRGB)
            retained.append((actual.image, bytes))
        }
        // Reader cache eviction and later decodes must not change an image already handed to the canvas.
        for (image, expected) in retained { #expect(try pixels(image) == expected) }
    }

    @Test func transformedAndDuplicatedFramesKeepTheirSourceMapping() async throws {
        var animation = try animation()
        animation.frameOrder = [GIFFrameReference(index: 0, sourceIndex: 0), GIFFrameReference(index: 6, sourceIndex: 2)]
        animation.geometry = GIFFrameGeometry(width: 24, height: 18,
            unitTransform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0))
        let expected = try GIFDecoder.frame(animation, index: 6, name: "Transformed")
        let actual = try await GIFPlaybackDecoder(animation, name: "Transformed").frame(at: 6).frame
        #expect(actual.image.width == 24 && actual.image.height == 18)
        #expect(try pixels(actual.image) == pixels(expected.image))
        #expect(try pixels(actual.thumbnail) == pixels(expected.thumbnail))
        #expect(actual.thumbnail !== animation.source.frames[2].thumbnail)

        animation.geometry = nil
        let duplicate = try await GIFPlaybackDecoder(animation, name: "Duplicate").frame(at: 6).frame
        #expect(duplicate.thumbnail === animation.source.frames[2].thumbnail)
    }

    @Test func editedFramesBypassDecodingAndCanceledReadsDoNotProduceFrames() async throws {
        var animation = try animation()
        let edited = try GIFDecoder.frame(animation, index: 3, name: "Edited")
        animation.framePixels[1] = edited
        let decoder = GIFPlaybackDecoder(animation, name: "Disposal")
        #expect(try await decoder.frame(at: 1).frame.image === edited.image)
        let canceled = Task { try await decoder.frame(at: 2) }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        await #expect(throws: ImageImportError.self) { try await decoder.frame(at: 99) }
        #expect(try await decoder.frame(at: 0).frame.thumbnail === animation.source.frames[0].thumbnail)
    }

    @Test func onlyCanonicalPixelsBypassTheRasterCopy() throws {
        let context = try BrushRaster.context(width: 16, height: 12, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 3))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 8, width: 8, height: 4))
        let image = try #require(context.makeImage())
        let reused = try GIFDecoder.raster(image, geometry: nil, keepsDecodedPixels: true)
        #expect(reused === image)
        #expect(try pixels(reused) == pixels(GIFDecoder.raster(image, geometry: nil, keepsDecodedPixels: false)))
    }

    @Test(arguments: [false, true]) func otherPixelLayoutsStillConvertToSRGB(p3: Bool) throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let image = try #require(context.makeImage())
        let actual = try GIFDecoder.raster(image, geometry: nil, keepsDecodedPixels: true)
        let expected = try GIFDecoder.raster(image, geometry: nil, keepsDecodedPixels: false)
        #expect(actual !== image && actual.colorSpace?.name == CGColorSpace.sRGB)
        #expect(try pixels(actual) == pixels(expected))
    }
}
