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

load :: (library: *Library_Data) -> [] *Album {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    albums: [] *Album;
    if library == null return albums;

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

event_loop :: (mpd_connection: *MPD.connection, albums: [] *Album, library: Library_Data, queue: *Queue.Data, frame: u64, font: *Simp.Dynamic_Font, total_width: s32, header_bottom: int, thumbnail_slot_width: s32, thumbnail_slot_height: s32) -> bool {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    selected_cover_highlight_width : s32 = thumbnail_slot_width / 25;

    MAX_HORIZONTAL_PADDING_FACTOR : s32 : 10;
    columns := (total_width + thumbnail_slot_width / MAX_HORIZONTAL_PADDING_FACTOR) / (thumbnail_slot_width + thumbnail_slot_width / MAX_HORIZONTAL_PADDING_FACTOR);
    horizontal_padding := ifx columns == 1 then 0 else cast(s32) ((total_width - columns * thumbnail_slot_width) / (columns - 1));
    {
        min_horizontal_padding := thumbnail_slot_width / MAX_HORIZONTAL_PADDING_FACTOR;
        if horizontal_padding < min_horizontal_padding && columns > 1 { // padding between columns is too small, remove a column
            columns -= 1;
            horizontal_padding = cast(s32) ((total_width - columns * thumbnail_slot_width) / (columns - 1));
        }
    }

    x_margin_offset : s32 = 0;
    {
        diff := horizontal_padding - thumbnail_slot_width / 3;
        if columns > 1 && diff > 0 { // padding between columns is too large, move the excess space into the margins
            x_margin_offset = (diff * (columns - 1)) / 2;
            horizontal_padding = cast(s32) ((total_width - columns * thumbnail_slot_width - 2 * x_margin_offset) / (columns - 1));
        } else if columns == 1 { // we only have one column, make sure it's centered
            x_margin_offset = (total_width - thumbnail_slot_width) / 2;
        }
    }

    total_height := header_bottom - Y_MARGIN_SIZE;
    footer_height := font.character_height + TEXT_PADDING_Y;
    total_album_entry_height := thumbnail_slot_height + 2 * (font.character_height + TEXT_PADDING_Y + selected_cover_highlight_width);

    MAX_VERTICAL_PADDING_FACTOR : s32 : 10;
    rows := (total_height - footer_height + thumbnail_slot_height / MAX_VERTICAL_PADDING_FACTOR) / (total_album_entry_height + thumbnail_slot_height / MAX_VERTICAL_PADDING_FACTOR);
    vertical_padding := ifx rows == 1 then 0 else cast(s32) ((total_height - rows * total_album_entry_height - footer_height) / (rows - 1));
    {
        min_vertical_padding := thumbnail_slot_height / MAX_VERTICAL_PADDING_FACTOR;
        if vertical_padding < min_vertical_padding && rows > 1 { // padding between rows is too small, remove a row
            rows -= 1;
            vertical_padding = cast(s32) ((total_height - rows * total_album_entry_height - footer_height) / (rows - 1));
        }
    }

    y_margin_offset : s32 = 0;
    {
        diff := vertical_padding - total_album_entry_height / 3;
        if rows > 1 && diff > 0 { // padding between rows is too large, move the excess space into the margins
            y_margin_offset = cast(s32) (diff * (rows - 1)) / 2;
            vertical_padding = cast(s32) ((total_height - rows * total_album_entry_height - footer_height - 2 * y_margin_offset) / (rows - 1));
        } else if rows == 1 { // we only have one row, make sure it's centered
            y_margin_offset = cast(s32)(total_height - total_album_entry_height - footer_height) / 2;
        }
    }

    album_songs_in_page := cast(int)(ALBUM_ART_DISPLAY_WIDTH - font.character_height) / (font.character_height + TEXT_PADDING_Y);

    original_subview := current_album_art_subview;

    user_input_active: bool;
    if current_album_art_subview == {
        case .LIBRARY;
            user_input_active = process_library_input(mpd_connection, albums, library, queue, frame, rows, columns);
        case .ALBUM;
            user_input_active = process_album_input(mpd_connection, queue, albums, frame, header_bottom, album_songs_in_page, albums[cursor.album_position]);
    }

    if current_album_art_subview == {
        case .LIBRARY;
            draw_library_frame(albums, font, header_bottom, rows, columns, total_width, total_height, thumbnail_slot_width, thumbnail_slot_height, horizontal_padding, vertical_padding, x_margin_offset, y_margin_offset, selected_cover_highlight_width);
        case .ALBUM;
            just_switched_to_album_subview := original_subview != .ALBUM;
            draw_album_frame(albums[cursor.album_position], just_switched_to_album_subview, font, total_width, header_bottom, album_songs_in_page);
    }

    return user_input_active;
}

#load "library_subview.jai";
#load "album_subview.jai";
