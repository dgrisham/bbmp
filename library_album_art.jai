#import "Hash_Table";
#import "Unicode";
#import "File_Utilities";

// library_album_art: struct {
//     albums : [..] Album_2;
// }

library_album_art: struct {
    albums                                : Table(string, Album_2);
    album_names_sorted_by_artist_and_date : [..] string;
}

Album_2 :: struct {
    name        : string;
    artist_name : string;
    date        : Date;
    songs       : [..] Song;
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

    assert(mpd_connection != null);
    MPD.send_list_all_meta(mpd_connection, "");
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");
    if !entity { print("Failed retrieving MPD metadata\n"); exit(1); }

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);

            mpd_artist   := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
            mpd_album    := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
            mpd_title    := MPD.song_get_tag(mpd_song, .TITLE       , 0);
            mpd_date     := MPD.song_get_tag(mpd_song, .DATE        , 0);
            if mpd_artist && mpd_album && mpd_title {
                song: Song;
                song.artist = copy_from_c_string(mpd_artist);
                song.album  = copy_from_c_string(mpd_album);
                song.name   = copy_from_c_string(mpd_title);

                album: Album_2;
                album.name        = song.album;
                album.artist_name = song.artist;
                album.date        = parse_date(to_string(mpd_date));

                insert_index := -1;
                for album_name, album_index: library_album_art.album_names_sorted_by_artist_and_date {
                    album_ptr := table_find_pointer(library_album_art.albums, album_name);
                    assert(album_ptr != null);

                    if compare_nocase(album.artist_name, album_ptr.artist_name) == 0 { // same artist
                        artist_first_album_index := album_index;
                        for i: artist_first_album_index..library_album_art.albums.count-1 { // compare to each album for this artist
                            album_name := library_album_art.album_names_sorted_by_artist_and_date[i];
                            album_ptr  := table_find_pointer(library_album_art.albums, album_name);
                            assert(album_ptr != null);
                            if compare_nocase(album.artist_name, album_ptr.artist_name) > 0 {
                                // we're past the last album for this artist, insert new album before this entry
                                insert_index = i;
                                break album_index;
                            }
                            if compare_nocase(album.artist_name, album_ptr.artist_name) == 0 {
                                if album.date < album_ptr.date {
                                    insert_index = i;
                                    break album_index;
                                }
                            }
                        }
                    }

                }
                if insert_index == -1 array_add(*library_album_art.album_names_sorted_by_artist_and_date, album.name);
                else                  array_insert_at(*library_album_art.album_names_sorted_by_artist_and_date, album.name, insert_index);

                song.track    = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK, 0));
                song.uri      = copy_from_c_string(MPD.song_get_uri(mpd_song));
                song.duration = MPD.song_get_duration(mpd_song);
                array_add(*album.songs, song);

                table_add(*library_album_art.albums, album.name, album);
            } else {
                // print("skipping: '%', '%', '%'\n", mpd_artist, to_string(mpd_album), to_string(mpd_title));
            }
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    print("library_album_art.album_names_sorted_by_artist_and_date: %\n", library_album_art.album_names_sorted_by_artist_and_date);
}

library_album_art_event_loop :: (frame: u64, header_bottom: int) {

    library_album_art_move_cursor_up :: () #expand {
        `library_album_art_cursor.position -= 1;
    }
    library_album_art_move_cursor_down :: () #expand {
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

    draw_library_album_art_frame(header_bottom);
}

library_album_art_cursor: struct {
    position := 0;
};

draw_library_album_art_frame :: (header_bottom: int) {

    Y_PADDING_BELOW_HEADER := 2 * Y_MARGIN_SIZE;

    texture_width  : s32 = 200;
    texture_height : s32 = texture_width;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - Y_MARGIN_SIZE;
    rows := total_height / texture_height - 1;

    total_width := cast(s32)display_width();
    columns := total_width / texture_width - 1;

    Entry :: struct {
        artist_name : string;
        album_name  : string;
        texture     : *Simp.Texture;
    };
    entries_to_draw: [..] Entry;
    entries_to_draw.allocator = __temporary_allocator;

    {
        max_entries_to_draw := rows * columns;
        array_reserve(*entries_to_draw, max_entries_to_draw);

        number_of_albums := 0;
        album_index  := 0;
        while entries_to_draw.count < max_entries_to_draw {
            album_name := library_album_art.album_names_sorted_by_artist_and_date[album_index];
            album := table_find_pointer(library_album_art.albums, album_name);
            if album == null { album_index += 1; continue; } // TODO: log error

            entry: Entry;
            entry.artist_name = album.artist_name;
            entry.album_name  = album.name;
            // TODO: thumbnail won't be in temporary storage, may not be freed correctly
            entry.texture = load_thumbnail_if_exists(entry.artist_name, entry.album_name);

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

            if entry.texture {
                Simp.set_shader_for_images(entry.texture);
                Simp.immediate_begin();
                Simp.immediate_quad(xy(x, y - texture_height), xy(x + texture_width, y - texture_height), xy(x + texture_width, y), xy(x, y));
                Simp.immediate_flush();
            } else {
                // Simp.set_shader_for_color();
                // Simp.immediate_quad(cast(float)x, cast(float)y, cast(float)x + texture_width, cast(float)y - texture_width, rgba(1,1,1,1));
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

load_thumbnail_if_exists :: (artist_name: string, album_name: string) -> *Simp.Texture {

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

    album_ptr := table_find_pointer(library_album_art.albums, album_name);
    assert(album_ptr != null);
    assert(album_ptr.songs.count > 0);

    thumbnail_filename: string = ---;
    {
        artist_and_album_string := tprint("%-%.bmp", artist_name, album_name);
        replace_chars(artist_and_album_string, " ", #char "_");

        builder: String_Builder;
        init_string_builder(*builder);
        for i: 0..artist_and_album_string.count-1 {
            c := artist_and_album_string[i];
            if is_alnum(c) || c == #char "-" || c == #char "." append(*builder, c);
        }
        thumbnail_filename = builder_to_string(*builder);
    }
    to_lower_in_place(thumbnail_filename);
        print("thumbnail_filename: %\n", thumbnail_filename);

    uri := album_ptr.songs[0].uri;
    thumbnail_path := tprint("/home/grish/src/jai/jai-mpd/.thumbnails/%", thumbnail_filename);

    if !file_exists(thumbnail_path) {
        log("Thumbnail not found for % - %, attempting to create", artist_name, album_name);
        if !create_album_art_thumbnail(uri, thumbnail_path) { // try to create thumbnail
            log("Failed to create thumbnail for % - %", artist_name, album_name, flags=.ERROR);
            return null;
        }
    }

    texture := New(Simp.Texture);
    if !Simp.texture_load_from_file(texture, thumbnail_path) {
        log("Failed to load thumbnail for % - %", artist_name, album_name, flags=.ERROR);

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
