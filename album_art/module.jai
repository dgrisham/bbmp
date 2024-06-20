#scope_module

#import "Basic";

#import "common";

MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";

Queue :: #import "queue";

cursor: struct {
    album_position : int = 0;
    song_position  : int = 0;
}

move_cursor_by_n_albums :: (number_of_albums: int, amount: int) #expand {
    `cursor.album_position += amount;
    if cursor.album_position < 0 {
        cursor.album_position = 0;
    } else if `cursor.album_position > number_of_albums - 1 {
        `cursor.album_position = number_of_albums - 1;
    }
}

move_cursor_to_prev_album :: () #expand { move_cursor_by_n_albums(`albums.count, -1); }
move_cursor_to_next_album :: () #expand { move_cursor_by_n_albums(`albums.count, +1); }

#scope_file

log_data :: Log_Data.{"album_art/main", false};

#scope_export

Subview :: enum {
    LIBRARY;
    ALBUM;
}

current_album_art_subview := Subview.LIBRARY;

load :: (library: Library_Data) -> [] *Album {

    context.logger_data = *log_data;

    albums: [] *Album;

    initialize_search_query(library_search_query);
    initialize_search_query(album_search_query);

    albums = NewArray(library.stats.number_of_albums, *Album);
    i := 0;
    for artist_name: library.artist_names_sorted {
        artist_ptr := table_find_pointer(*library.artists, artist_name);
        assert(artist_ptr != null, "Failed to find artist '%' in table when loading library album art data", artist_name);

        for album_name: artist_ptr.album_names_sorted_by_date {
            album_ptr := table_find_pointer(*artist_ptr.albums, album_name);
            assert(album_ptr != null, "Failed to find album '%' - '%' in table when loading library album art data", artist_name, album_name);
            albums[i] = album_ptr;
            i += 1;
        }
    }

    return albums;
}

event_loop :: (mpd_connection: *MPD.connection, albums: [] *Album, library: Library_Data, queue: *Queue.Data, frame: u64, boundary: View_Boundary) -> bool {

    context.logger_data = *log_data;

    selected_cover_highlight_width : s32 = cast(s32) (thumbnail_slot_width / (fonts.regular.character_height * 2));
    // min_padding_between_covers := 0.1 * thumbnail_slot_width;

    min_x_padding := selected_cover_highlight_width * 2 + 0.05 * thumbnail_slot_width; // @TODO @Hardcoded
    // calculate the number of columns we can fit with the minimum padding
    columns := cast (s32) (((boundary.width - 2 * selected_cover_highlight_width) + min_x_padding) / (thumbnail_slot_width + min_x_padding));
    // calculate the padding we would actually use with this number of columns
    x_padding_between_album_covers := ifx columns == 1 then 0 else cast(s32) ((boundary.width - selected_cover_highlight_width - columns * thumbnail_slot_width) / (columns - 1));

    total_album_entry_height := thumbnail_slot_height + 2 * (line_height + selected_cover_highlight_width);
    footer_height := line_height;

    min_y_padding := selected_cover_highlight_width + 0.05 * thumbnail_slot_height; // @TODO @Hardcoded
    rows := cast(s32) ((boundary.height - footer_height + min_y_padding) / (total_album_entry_height + min_y_padding));
    y_padding_between_album_covers := ifx rows == 1 then 0 else cast(s32) ((boundary.height - rows * total_album_entry_height - footer_height) / (rows - 1));

    // line_height is subtracted here so the album cover is always at least a bit above/below the tracklist
    album_songs_in_page := cast(int)(ALBUM_ART_DISPLAY_WIDTH - line_height) / line_height;

    original_subview := current_album_art_subview;

    user_input_active: bool;
    if current_album_art_subview == {
        case .LIBRARY;
            user_input_active = process_library_input(mpd_connection, albums, library, queue, frame, rows, columns);
        case .ALBUM;
            user_input_active = process_album_input(mpd_connection, library, queue, albums, frame, boundary, album_songs_in_page, albums[cursor.album_position]);
    }

    if current_album_art_subview == {

        case .LIBRARY;

            // calculate the additional margin required to center the album art grid
            x_margin_offset : s64 = 0;
            {
                diff := x_padding_between_album_covers - thumbnail_slot_width / 3;
                if columns > 1 && diff > 0 { // padding between columns is too large, move the excess space into the margins
                    x_margin_offset = (diff * (columns - 1)) / 2;
                    x_padding_between_album_covers = cast(s32) ((boundary.width - columns * thumbnail_slot_width - 2 * x_margin_offset) / (columns - 1));
                } else if columns == 1 { // we only have one column, make sure it's centered
                    x_margin_offset = (boundary.width - thumbnail_slot_width) / 2;
                }
            }
            y_margin_offset : s32 = 0;
            {
                diff := y_padding_between_album_covers - total_album_entry_height / 3.0;
                if rows > 1 && diff > 0 { // padding between rows is too large, move the excess space into the margins
                    y_margin_offset = cast(s32) (diff * (rows - 1)) / 2;
                    y_padding_between_album_covers = cast(s32) ((boundary.height - rows * total_album_entry_height - footer_height - 2 * y_margin_offset) / (rows - 1));
                } else if rows == 1 { // we only have one row, make sure it's centered
                    y_margin_offset = cast(s32)(boundary.height - total_album_entry_height - footer_height) / 2;
                }
            }

            library_boundary := view_boundary(
                top    = boundary.top - y_margin_offset,
                bottom = boundary.bottom + y_margin_offset,
                left   = boundary.left + x_margin_offset,
                right  = boundary.right - x_margin_offset,
            );
            draw_library_frame(albums, library.allocator, library_boundary, rows, columns, x_padding_between_album_covers, y_padding_between_album_covers, selected_cover_highlight_width);

        case .ALBUM;
            just_switched_to_album_subview := original_subview != .ALBUM;
            draw_album_frame(albums[cursor.album_position], queue, just_switched_to_album_subview, boundary, album_songs_in_page);
    }

    return user_input_active;
}

#load "library_subview.jai";
#load "album_subview.jai";
