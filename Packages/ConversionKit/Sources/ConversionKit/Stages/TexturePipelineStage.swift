import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-preset texture rules (specs/conversion-pipeline.md, stage 6):
/// resize to max, format policy — normal maps and data textures stay PNG,
/// albedo optionally JPEG.
public struct TexturePolicy: Hashable, Sendable {
    public var maxSize: Int
    public var encodeBaseColorAsJPEG: Bool
    public var jpegQuality: Double

    public init(maxSize: Int = 2048, encodeBaseColorAsJPEG: Bool = false, jpegQuality: Double = 0.9) {
        self.maxSize = maxSize
        self.encodeBaseColorAsJPEG = encodeBaseColorAsJPEG
        self.jpegQuality = jpegQuality
    }
}

/// The material inputs a texture can feed. Data textures (normal, ORM,
/// occlusion) must stay lossless; only color textures may go JPEG.
public enum TextureSlot: String, CaseIterable, Sendable {
    case baseColor
    case metallicRoughness
    case normal
    case occlusion
    case emissive

    var keyPath: WritableKeyPath<PBRMaterial, TextureRef?> {
        switch self {
        case .baseColor: \.baseColorTexture
        case .metallicRoughness: \.metallicRoughnessTexture
        case .normal: \.normalTexture
        case .occlusion: \.occlusionTexture
        case .emissive: \.emissiveTexture
        }
    }

    var mustStayLossless: Bool {
        switch self {
        case .normal, .metallicRoughness, .occlusion: true
        case .baseColor, .emissive: false
        }
    }
}

/// Output encoding decision for one texture.
public enum TextureFormat: String, Sendable {
    case png = "image/png"
    case jpeg = "image/jpeg"
}

/// Stage 6 of the standard sequence: decode every texture reference,
/// resize to the preset max, re-encode per format policy, and inline the
/// bytes so packaging never depends on source-relative paths.
public struct TexturePipelineStage: ConversionStage {
    public let id = "textures"
    public var policy: TexturePolicy

    /// Injectable image ops so CG-failure fallbacks stay testable.
    var resizeFunction: @Sendable (CGImage, Int, Int) -> CGImage? = TextureProcessor.resize
    var encodeFunction: @Sendable (CGImage, TextureFormat, Double) -> Data? = TextureProcessor.encode

    public init(policy: TexturePolicy = TexturePolicy()) {
        self.policy = policy
    }

    // MARK: - Pure policy decisions (unit-tested directly)

    /// Longest side clamped to `maxSize`, aspect preserved, never upscaled.
    /// Returns nil when no resize is needed.
    static func targetSize(width: Int, height: Int, maxSize: Int) -> (width: Int, height: Int)? {
        let longest = max(width, height)
        guard longest > maxSize, maxSize > 0, width > 0, height > 0 else { return nil }
        let scale = Double(maxSize) / Double(longest)
        return (
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// Format policy: data textures always PNG; color textures JPEG only
    /// when the preset opts in and the material has no alpha to preserve.
    static func outputFormat(slot: TextureSlot, alphaMode: AlphaMode, policy: TexturePolicy) -> TextureFormat {
        if slot.mustStayLossless { return .png }
        if slot == .baseColor && alphaMode != .opaque { return .png }
        return policy.encodeBaseColorAsJPEG ? .jpeg : .png
    }

    // MARK: - Stage

    public func process(_ context: inout ConversionContext) async throws {
        let baseURL = context.sourceURL.deletingLastPathComponent()
        for materialIndex in context.scene.materials.indices {
            for slot in TextureSlot.allCases {
                guard let ref = context.scene.materials[materialIndex][keyPath: slot.keyPath] else { continue }
                let materialName = context.scene.materials[materialIndex].name
                let label = "\(materialName).\(slot.rawValue)"

                guard let bytes = load(ref, baseURL: baseURL) else {
                    context.diagnostics.append(Diagnostic(
                        severity: .warning, stage: id,
                        message: "\(label): texture could not be read — reference kept as-is"))
                    continue
                }
                guard let image = TextureProcessor.decode(bytes) else {
                    context.diagnostics.append(Diagnostic(
                        severity: .warning, stage: id,
                        message: "\(label): undecodable image data — reference kept as-is"))
                    continue
                }

                var output = image
                if let target = Self.targetSize(width: image.width, height: image.height, maxSize: policy.maxSize) {
                    guard let resized = resizeFunction(image, target.width, target.height) else {
                        context.diagnostics.append(Diagnostic(
                            severity: .warning, stage: id,
                            message: "\(label): resize failed — keeping original resolution"))
                        continue
                    }
                    output = resized
                    context.diagnostics.append(Diagnostic(
                        severity: .info, stage: id,
                        message: "\(label): resized \(image.width)x\(image.height) → \(target.width)x\(target.height)"))
                }

                let format = Self.outputFormat(
                    slot: slot,
                    alphaMode: context.scene.materials[materialIndex].alphaMode,
                    policy: policy
                )
                guard let encoded = encodeFunction(output, format, policy.jpegQuality) else {
                    context.diagnostics.append(Diagnostic(
                        severity: .warning, stage: id,
                        message: "\(label): re-encode failed — reference kept as-is"))
                    continue
                }
                context.scene.materials[materialIndex][keyPath: slot.keyPath] =
                    TextureRef(source: .data(encoded), mimeType: format.rawValue)
            }
        }
    }

    private func load(_ ref: TextureRef, baseURL: URL) -> Data? {
        switch ref.source {
        case .data(let data):
            return data
        case .uri(let uri):
            guard let resolved = URL(string: uri, relativeTo: baseURL) else { return nil }
            return try? Data(contentsOf: resolved.absoluteURL)
        }
    }
}

/// CoreGraphics-backed image operations shared by the texture stage.
/// Kept small and separately testable.
public enum TextureProcessor {

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func encode(_ image: CGImage, format: TextureFormat, jpegQuality: Double) -> Data? {
        let type: UTType = format == .png ? .png : .jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            // coverage:disable — CGImageDestinationCreateWithData cannot fail
            // for the two fixed, always-supported UTTypes above; defensive only.
            return nil
        }
        let options: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: jpegQuality]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Channel handling for ORM-style packed textures: extract one channel
    /// (r/g/b) into an 8-bit grayscale image — occlusion reads R, roughness
    /// G, metallic B (specs/conversion-pipeline.md material table).
    public enum Channel: Int, Sendable {
        case red = 0
        case green = 1
        case blue = 2
    }

    public static func extractChannel(_ channel: Channel, from image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let rgbaContext = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        rgbaContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgba = rgbaContext.data else { return nil }

        guard let grayContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let gray = grayContext.data else { return nil }

        let source = rgba.assumingMemoryBound(to: UInt8.self)
        let destination = gray.assumingMemoryBound(to: UInt8.self)
        let sourceStride = rgbaContext.bytesPerRow
        let destinationStride = grayContext.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                destination[y * destinationStride + x] = source[y * sourceStride + x * 4 + channel.rawValue]
            }
        }
        return grayContext.makeImage()
    }
}
