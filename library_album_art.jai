#import "Hash_Table";
#import "Unicode";
#import "File_Utilities";

library_album_art: struct {
    albums : [..] *Album;
}

// library_album_art: struct {
//     albums                                : Table(string, *Album);
//     albums                                : Table(string, *Album);
//     album_names_sorted_by_artist_and_date : [..] string;
// }

library_album_art_cursor: struct {
    position := 0;
};

last_library_album_art_key_pressed: Key;
library_album_art_key_pressed_on_frame: Table(Key, u64);

library_album_art_init_repeatable_keys :: () {
    table_set(*library_album_art_key_pressed_on_frame, .J,      0);
    table_set(*library_album_art_key_pressed_on_frame, .K,      0);
    table_set(*library_album_art_key_pressed_on_frame, .L,      0);
    table_set(*library_album_art_key_pressed_on_frame, .H,      0);
    table_set(*library_album_art_key_pressed_on_frame, .CTRL_D, 0);
    table_set(*library_album_art_key_pressed_on_frame, .CTRL_U, 0);
    table_set(*library_album_art_key_pressed_on_frame, .SPACE,  0);
}

load_library_album_art :: () {

    array_resize(*library_album_art.albums, library_stats.number_of_albums);
    i := 0;
    for artist: library.artists {
        for * album_ptr: artist.albums {
            library_album_art.albums[i] = album_ptr;
            i += 1;
        }
    }

    // print("library_album_art.albums: %\n", library_album_art.albums);
}

library_album_art_event_loop :: (frame: u64, header_bottom: int) {

    Y_PADDING_BELOW_HEADER := 2 * Y_MARGIN_SIZE;

    texture_width  : s32 = 200;
    texture_height : s32 = texture_width;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - Y_MARGIN_SIZE;
    rows := total_height / texture_height - 1;

    total_width := cast(s32)display_width();
    columns := total_width / texture_width - 1;

    library_album_art_move_cursor_up :: () #expand {
        `library_album_art_cursor.position -= columns;
    }
    library_album_art_move_cursor_down :: () #expand {
        `library_album_art_cursor.position += columns;
    }
    library_album_art_move_cursor_left :: () #expand {
        `library_album_art_cursor.position -= 1;
    }
    library_album_art_move_cursor_right :: () #expand {
        `library_album_art_cursor.position += 1;
    }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    table_set(*library_album_art_key_pressed_on_frame, .J, frame);
                    last_library_album_art_key_pressed = .J;
                    library_album_art_move_cursor_down();
                    break it;
                  case KEY_K;
                    table_set(*library_album_art_key_pressed_on_frame, .K, frame);
                    last_library_album_art_key_pressed = .K;
                    library_album_art_move_cursor_up();
                    break it;

                  case KEY_H;
                    table_set(*library_album_art_key_pressed_on_frame, .H, frame);
                    last_library_album_art_key_pressed = .H;
                    library_album_art_move_cursor_left();
                    break it;
                  case KEY_L;
                    table_set(*library_album_art_key_pressed_on_frame, .L, frame);
                    last_library_album_art_key_pressed = .L;
                    library_album_art_move_cursor_right();
                    break it;

                  // case KEY_D;
                  //   if it.ctrl_pressed {
                  //       table_set(*library_album_art_key_pressed_on_frame, .CTRL_D, frame);
                  //       last_library_album_art_key_pressed = .CTRL_D;
                  //       library_album_art_move_cursor_one_page_down();
                  //   }
                  //   break it;
                  // case KEY_U;
                  //   if it.ctrl_pressed {
                  //       table_set(*library_album_art_key_pressed_on_frame, .CTRL_U, frame);
                  //       last_library_album_art_key_pressed = .CTRL_U;
                  //       library_album_art_move_cursor_one_page_up();
                  //   }
                  //   break it;

                  // case KEY_G;
                  //   if it.shift_pressed {
                  //       library_album_art_cursor.position = library_album_art.songs.count - 1;
                  //   } else {
                  //       library_album_art_cursor.position = 0;
                  //   }
                  //   break it;

                  // case;
                    // print("key_code: %\n", it.key_code);
                }
            }

        }
    }

    if library_album_art_cursor.position < 0 {
        library_album_art_cursor.position = 0;
    } else if library_album_art_cursor.position > library_album_art.albums.count - 1 {
        library_album_art_cursor.position = library_album_art.albums.count - 1;
    }

    {
        Entry :: struct {
            artist_name : string;
            album_name  : string;
            texture     : *Simp.Texture;
            selected    : bool;
        };
        entries_to_draw: [..] Entry;
        entries_to_draw.allocator = __temporary_allocator;

        {
            max_entries_to_draw := rows * columns;
            array_reserve(*entries_to_draw, max_entries_to_draw);

            number_of_albums := 0;
            // get index of first album to draw based on cursor position
            x := library_album_art_cursor.position / columns * columns;
            album_index := max(0, min(x - columns, library_album_art.albums.count - 1));
            selected_album_index := album_index + library_album_art_cursor.position % columns + ifx x < 7 then 0 else columns;
            while entries_to_draw.count < max_entries_to_draw {
                album := library_album_art.albums[album_index];

                entry: Entry;
                entry.artist_name = album.artist_name;
                entry.album_name  = album.name;
                // TODO: thumbnail won't be in temporary storage, may not be freed correctly
                entry.texture = load_thumbnail_if_exists(album_index);
                entry.selected = album_index == selected_album_index;

                array_add(*entries_to_draw, entry);

                album_index += 1;
                if album_index == library_album_art.albums.count {
                    break;
                }
            }
        }

        {
            HORIZONTAL_PADDING := (total_width  - columns * texture_width) / columns;
            VERTICAL_PADDING   := (total_height - rows    * texture_height) / rows;

            x := cast(float)X_MARGIN_SIZE;
            y := cast(float)header_bottom - Y_PADDING_BELOW_HEADER;

            row, column := 0;
            for entry: entries_to_draw {

                if entry.selected {
                    SELECTED_COVER_HIGHLIGHT_WIDTH :: 4;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)x - SELECTED_COVER_HIGHLIGHT_WIDTH, cast(float)y + SELECTED_COVER_HIGHLIGHT_WIDTH, cast(float)x + texture_width + SELECTED_COVER_HIGHLIGHT_WIDTH, cast(float)y - texture_width - SELECTED_COVER_HIGHLIGHT_WIDTH, rgba(1,1,1,1));
                }

                if entry.texture {
                    Simp.set_shader_for_images(entry.texture);
                    Simp.immediate_begin();
                    Simp.immediate_quad(xy(x, y - texture_height), xy(x + texture_width, y - texture_height), xy(x + texture_width, y), xy(x, y));
                    Simp.immediate_flush();
                }

                column += 1;
                if column == columns {
                    row += 1;
                    column = 0;
                    x = cast(float)X_MARGIN_SIZE;
                    y -= texture_width;
                    y -= VERTICAL_PADDING;
                } else {
                    x += texture_width;
                    x += HORIZONTAL_PADDING;
                }
            }
        }
    }
}

load_thumbnail_if_exists :: (album_index: s64) -> *Simp.Texture {

    create_album_art_thumbnail :: (uri: string, thumbnail_path: string) -> bool {

        // load the album art from MPD
        album_art_data: [..] u8;
        defer array_free(album_art_data);
        if !load_album_art(uri, *album_art_data) {
            log("Failed to load album art for song URI '%'", uri, flags=.ERROR);
            return false;
        }

        // load the raw data into a bitmap
        bitmap: Simp.Bitmap;
        defer Simp.deinit(*bitmap);
        if !Simp.bitmap_load_from_memory(*bitmap, album_art_data) {
            log("Failed to load album art into bitmap for song URI '%'", uri, flags=.ERROR);
            return false;
        }

        // resize to thumbnail size
        resized_bitmap: Simp.Bitmap;
        Simp.bitmap_resize(*bitmap, THUMBNAIL_WIDTH, cast(s32)(bitmap.height * cast(float64)THUMBNAIL_WIDTH / bitmap.width), *resized_bitmap);
        defer Simp.deinit(*resized_bitmap);

        // save the thumbnail
        if !Simp.bitmap_save(*resized_bitmap, thumbnail_path) {
            log("Failed to save album art thumbnail to '%'", thumbnail_path, flags=.ERROR);
            return false;
        }

        log("Saved album art thumbnail to '%'", thumbnail_path);

        return true;
    }

    album := library_album_art.albums[album_index];

    // thumbnail_filename: string = ---;
    // {
    //     artist_and_album_string := tprint("%-%.bmp", album.artist_name, album.name);
    //     replace_chars(artist_and_album_string, " ", #char "_");

    //     builder: String_Builder;
    //     init_string_builder(*builder);
    //     for i: 0..artist_and_album_string.count-1 {
    //         c := artist_and_album_string[i];
    //         if is_alnum(c) || c == #char "-" || c == #char "." append(*builder, c);
    //     }
    //     thumbnail_filename = builder_to_string(*builder);
    // }

    thumbnail_filename := tprint("%-%.bmp", album.artist_name, album.name);
    replace_chars(thumbnail_filename, " ", #char "_");

    to_lower_in_place(thumbnail_filename);
    print("thumbnail_filename: %\n", thumbnail_filename);

    uri := album.songs[0].uri;
    thumbnail_path := tprint("/home/grish/src/jai/jai-mpd/.thumbnails/%", thumbnail_filename);

    if !file_exists(thumbnail_path) {
        log("Thumbnail not found for % - %, attempting to create", album.artist_name, album.name);
        if !create_album_art_thumbnail(uri, thumbnail_path) { // try to create thumbnail
            log("Failed to create thumbnail for % - %", album.artist_name, album.name, flags=.ERROR);
            return null;
        }
    }

    texture := New(Simp.Texture);
    if !Simp.texture_load_from_file(texture, thumbnail_path) {
        log("Failed to load thumbnail for % - %", album.artist_name, album.name, flags=.ERROR);
        return null;
    }

    return texture;
}

THUMBNAIL_WIDTH :: 300;
organize_this_stuff :: () {
    // album_ptr.texture = load_thumbnail_if_exists("Metallica", "Master of Puppets");

    // if !create_album_art_thumbnail(uri, thumbnail_path) {
    //     log("Failed to create thumbnail for % - %", artist_name, album_name, flags=.ERROR);
    // }
}

BUFFER_MAX :: 8192;
load_album_art :: (uri: string, data: *[..] u8) -> success: bool {
    assert(data.count == 0);

    buffer: [BUFFER_MAX] u8;
    while true {
        bytes_read := MPD.run_albumart(mpd_connection, uri.data, cast(u32)data.count, buffer.data, BUFFER_MAX);
        if bytes_read < 0 {
            handle_errors(tprint("Retrieving album art for song uri: %", uri));
            return false;
        }
        array_add(data, ..buffer);
        if bytes_read < BUFFER_MAX return true;
    }

    return true;
}
