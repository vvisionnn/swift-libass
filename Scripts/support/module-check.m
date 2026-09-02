@import LibASS;

int main(void) {
    ASS_Library *library = ass_library_init();
    if (!library) return 1;
    ASS_Renderer *renderer = ass_renderer_init(library);
    if (!renderer) {
        ass_library_done(library);
        return 2;
    }
    ass_renderer_done(renderer);
    ass_library_done(library);
    return ass_library_version() != LIBASS_VERSION;
}
