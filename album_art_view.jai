Album_Art_Subview :: enum {
    LIBRARY;
    ALBUM;
}

current_album_art_subview := Album_Art_Subview.LIBRARY;

#load "album_art_view_library.jai";
#load "album_art_view_album.jai";

album_art_event_loop :: (frame: u64, header_bottom: int) {

    Y_PADDING_BELOW_HEADER := Y_MARGIN_SIZE;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - 2 * Y_MARGIN_SIZE;
    rows := total_height / THUMBNAIL_SLOT_HEIGHT - 1;

    total_width := cast(s32)display_width();
    columns := total_width / THUMBNAIL_SLOT_WIDTH - 1;

    song_list_height := header_bottom - 3 * Y_MARGIN_SIZE - 3 * (TEXT_PADDING_Y + font.character_height) - TEXT_PADDING_Y;
    album_songs_in_page := cast(int)(song_list_height - font.character_height) / (font.character_height + TEXT_PADDING_Y);

    original_subview := current_album_art_subview;

    if current_album_art_subview == {
        case .LIBRARY;
            library_album_art_process_input(frame, rows, columns);
        case .ALBUM;
            album_process_input(frame, header_bottom, album_songs_in_page, library_album_art.albums[library_album_art_cursor.album_position]);
    }

    if current_album_art_subview == {
        case .LIBRARY;
            library_album_art_draw_one_frame(header_bottom, rows, columns, total_width, total_height, Y_PADDING_BELOW_HEADER);
        case .ALBUM;
            just_switched_to_album_subview := original_subview != .ALBUM;
            draw_album_frame(library_album_art.albums[library_album_art_cursor.album_position], just_switched_to_album_subview, header_bottom, album_songs_in_page);
    }
}
