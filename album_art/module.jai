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

#scope_export

Subview :: enum {
    LIBRARY;
    ALBUM;
}

current_album_art_subview := Subview.LIBRARY;

load :: (library: *Library_Data) -> [..] *Album {

    albums: [..] *Album;

    array_resize(*albums, library.stats.number_of_albums);
    i := 0;
    for artist_name: library.artist_names_sorted {
        artist_ptr := table_find_pointer(library.artists, artist_name);
        assert(artist_ptr != null, "Failed to find artist '%' in table when loading library album art data", artist_name);

        for album_name: artist_ptr.album_names_sorted_by_date {
            album_ptr := table_find_pointer(artist_ptr.albums, album_name);
            assert(album_ptr != null, "Failed to find album '%' - '%' in table when loading library album art data", artist_name, album_name);

            albums[i] = album_ptr;
            i += 1;
        }
    }

    return albums;
}

event_loop :: (mpd_connection: *MPD.connection, albums: [..] *Album, library: Library_Data, queue: *Queue.Data, frame: u64, font: *Simp.Dynamic_Font, total_width: s32, header_bottom: int, thumbnail_slot_width: s32, thumbnail_slot_height: s32) {

    Y_PADDING_BELOW_HEADER := Y_MARGIN_SIZE;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - 2 * Y_MARGIN_SIZE;
    rows := total_height / thumbnail_slot_height - 1;

    columns := total_width / thumbnail_slot_width - 1;

    song_list_height := header_bottom - 3 * Y_MARGIN_SIZE - 3 * (TEXT_PADDING_Y + font.character_height) - TEXT_PADDING_Y;
    album_songs_in_page := cast(int)(song_list_height - font.character_height) / (font.character_height + TEXT_PADDING_Y);

    original_subview := current_album_art_subview;

    if current_album_art_subview == {
        case .LIBRARY;
            process_library_input(mpd_connection, albums, library, queue, frame, rows, columns);
        case .ALBUM;
            process_album_input(mpd_connection, queue, albums, frame, header_bottom, album_songs_in_page, albums[cursor.album_position]);
    }

    if current_album_art_subview == {
        case .LIBRARY;
            draw_library_frame(albums, font, header_bottom, rows, columns, total_width, total_height, thumbnail_slot_width, thumbnail_slot_height, Y_PADDING_BELOW_HEADER);
        case .ALBUM;
            just_switched_to_album_subview := original_subview != .ALBUM;
            draw_album_frame(albums[cursor.album_position], just_switched_to_album_subview, font, total_width, header_bottom, album_songs_in_page);
    }
}

#load "library_subview.jai";
#load "album_subview.jai";
