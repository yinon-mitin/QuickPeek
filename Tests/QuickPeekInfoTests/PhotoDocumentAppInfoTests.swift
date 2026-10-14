import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import QuickPeekInfo

func info(_ url: URL) -> FileInfo {
    FileInfoReader.read(url, locale: Locale(identifier: "en_US"))
}

@Suite("FileInfo: photos")
struct PhotoInfoTests {
    /// A 64×48 JPEG with camera EXIF and a GPS position, written with ImageIO.
    private func makePhoto() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qp-\(UUID().uuidString).jpg")
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "QuickPeek", kCGImagePropertyTIFFModel: "Test Camera"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifDateTimeOriginal: "2026:01:02 15:30:00", kCGImagePropertyExifLensModel: "Test Lens 35mm F2.8",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 32.0853, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 34.7818, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 15.0,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("Image size, colour and camera EXIF")
    func exif() throws {
        let photo = info(try makePhoto())
        #expect(photo.value("Format", in: "Image") == "JPEG")
        #expect(photo.value("Resolution", in: "Image") == "64 × 48")
        #expect(photo.value("Colour model", in: "Image") == "RGB")
        #expect(photo.value("Camera", in: "Camera") == "QuickPeek Test Camera")
        #expect(photo.value("Lens", in: "Camera") == "Test Lens 35mm F2.8")
        #expect(photo.value("Exposure", in: "Camera") == "1/250 s")
        #expect(photo.value("Aperture", in: "Camera") == "f/2.8")
        #expect(photo.value("ISO", in: "Camera") == "400")
        #expect(photo.value("Focal length", in: "Camera") == "35 mm")
        #expect(photo.value("Taken", in: "Camera") != nil)
        #expect(photo.summary == "64×48 · JPEG · QuickPeek Test Camera")
    }

    @Test("GPS position")
    func location() throws {
        let photo = info(try makePhoto())
        #expect(photo.value("Coordinates", in: "Location") == "32.0853° N, 34.7818° E")
        #expect(photo.value("Altitude", in: "Location") == "15 m")
    }

    static let rawSample = repositoryRoot.appendingPathComponent("build/samples2/ZV-E10.ARW")

    /// RAW samples are tens of megabytes, so they are not in the repository. Download one from
    /// raw.pixls.us (Sony ZV-E10) to build/samples2/ZV-E10.ARW to run this test.
    @Test("Sony RAW", .enabled(if: FileManager.default.fileExists(atPath: rawSample.path), "no local ARW sample"))
    func raw() throws {
        let raw = info(Self.rawSample)
        #expect(raw.value("Resolution", in: "Image") == "6000 × 4000")
        #expect(raw.value("Camera", in: "Camera")?.contains("ZV-E10") == true)
    }
}

@Suite("FileInfo: Office documents")
struct OfficeInfoTests {
    let fixtures = repositoryRoot.appendingPathComponent("Tests/QuickPeekFormatsTests/Fixtures")

    @Test("Word: properties and statistics")
    func word() {
        let document = info(fixtures.appendingPathComponent("report.docx"))
        #expect(document.value("Title", in: "Document") == "Annual Report")
        #expect(document.value("Author", in: "Document") == "Ada Lovelace")
        #expect(document.value("Last modified by", in: "Document") == "Charles Babbage")
        #expect(document.value("Pages", in: "Document") == "3")
        #expect(document.value("Words", in: "Document") == "1,200")
        #expect(document.value("Application", in: "Document") == "Microsoft Office Word")
        #expect(document.summary == "3 pages · 1,200 words")
    }

    @Test("Excel sheets and PowerPoint slides")
    func sheetsAndSlides() {
        let workbook = info(fixtures.appendingPathComponent("budget.xlsx"))
        #expect(workbook.value("Sheets", in: "Document") == "3 (Income, Expenses, Summary)")
        let deck = info(fixtures.appendingPathComponent("deck.pptx"))
        #expect(deck.value("Slides", in: "Document") == "12")
        #expect(deck.summary == "12 slides")
    }
}

@Suite("FileInfo: applications")
struct AppInfoTests {
    @Test("App bundle: identity, version, architectures and signature")
    func calculator() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let app = info(url)
        #expect(app.value("Bundle ID", in: "Application") == "com.apple.calculator")
        #expect(app.value("Architectures", in: "Application")?.contains("arm64") == true)
        #expect(app.value("Signed by", in: "Signature")?.contains("Apple") == true)
        #expect(app.value("Version", in: "Application") != nil)
    }
}
