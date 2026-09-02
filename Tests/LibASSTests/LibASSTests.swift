import Foundation
import LibASS
@testable import LibASSLinkerSupport
import Testing

@Test func runtimeMatchesBundledHeaders() {
    #expect(ass_library_version() == LIBASS_VERSION)
}

private func withTrack(
    text: String = "Hello, subtitles!",
    _ body: (OpaquePointer, UnsafeMutablePointer<ASS_Track>) throws -> Void
) throws {
    let library = try #require(ass_library_init())
    defer { ass_library_done(library) }
    let renderer = try #require(ass_renderer_init(library))
    defer { ass_renderer_done(renderer) }
    ass_set_frame_size(renderer, 640, 360)
    ass_set_storage_size(renderer, 640, 360)
    ass_set_fonts(renderer, nil, "Helvetica", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)

    let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,32,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\(text)
    """
    var bytes = Array(script.utf8CString)
    let track = try bytes.withUnsafeMutableBufferPointer { buffer in
        try #require(ass_read_memory(library, buffer.baseAddress, buffer.count - 1, nil))
    }
    defer { ass_free_track(track) }
    try body(renderer, track)
}

@Test func parsesAuthoredTrack() throws {
    try withTrack { _, track in
        #expect(track.pointee.n_events == 1)
        #expect(track.pointee.n_styles >= 1)
        #expect(track.pointee.PlayResX == 640)
        #expect(track.pointee.PlayResY == 360)
        #expect(track.pointee.events.pointee.Start == 1_000)
        #expect(track.pointee.events.pointee.Duration == 2_000)
    }
}

@Test func rendersStyledPixels() throws {
    try withTrack(text: "{\\b1\\i1\\c&H00FF00&}Styled subtitles") { renderer, track in
        var changed: Int32 = 0
        let first = try #require(ass_render_frame(renderer, track, 1_500, &changed))
        #expect(changed != 0)
        var current: UnsafeMutablePointer<ASS_Image>? = first
        var visiblePixels = 0
        while let image = current {
            #expect(image.pointee.w > 0)
            #expect(image.pointee.h > 0)
            for row in 0..<Int(image.pointee.h) {
                for column in 0..<Int(image.pointee.w) {
                    if image.pointee.bitmap[row * Int(image.pointee.stride) + column] > 0 {
                        visiblePixels += 1
                    }
                }
            }
            current = image.pointee.next
        }
        #expect(visiblePixels > 100)
    }
}

@Test func shapesBidirectionalText() throws {
    try withTrack(text: "Hello مرحبا שלום") { renderer, track in
        var changed: Int32 = 0
        #expect(ass_render_frame(renderer, track, 1_500, &changed) != nil)
    }
}

@Test func respectsEventBoundariesAndFlush() throws {
    try withTrack { renderer, track in
        var changed: Int32 = 0
        #expect(ass_render_frame(renderer, track, 999, &changed) == nil)
        #expect(ass_render_frame(renderer, track, 1_000, &changed) != nil)
        #expect(ass_render_frame(renderer, track, 3_000, &changed) == nil)
        ass_flush_events(track)
        #expect(track.pointee.n_events == 0)
        #expect(ass_render_frame(renderer, track, 1_500, &changed) == nil)
    }
}

@Test func rejectsMalformedScript() throws {
    let library = try #require(ass_library_init())
    defer { ass_library_done(library) }
    var bytes = Array("not an ASS document".utf8CString)
    bytes.withUnsafeMutableBufferPointer { buffer in
        let track = ass_read_memory(library, buffer.baseAddress, buffer.count - 1, nil)
        #expect(track == nil)
        if let track { ass_free_track(track) }
    }
}

@Test func bundlesRequiredPrivacyDeclaration() throws {
    let url = try #require(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    let data = try Data(contentsOf: url)
    let document = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(document["NSPrivacyTracking"] as? Bool == false)
    #expect((document["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    #expect((document["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    let entries = try #require(document["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp")
    #expect(Set(try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])) == ["C617.1", "3B52.1"])
}
