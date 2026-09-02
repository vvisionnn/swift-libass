import LibASS

precondition(ass_library_version() == LIBASS_VERSION)
let library = ass_library_init()!
let renderer = ass_renderer_init(library)!
ass_set_frame_size(renderer, 640, 360)
ass_set_fonts(renderer, nil, "Helvetica", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
let track = ass_new_track(library)!
ass_free_track(track)
ass_renderer_done(renderer)
ass_library_done(library)
print("LibASS standalone link and lifecycle passed: \(ass_library_version())")
