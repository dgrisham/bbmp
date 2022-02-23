#import "Hash_Table";
#import "Unicode";
#import "File_Utilities";
#import "Hash";

library_album_art: struct {
    albums : [..] *Album;
}

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
    array_resize(*library_album_art.albums, library.stats.number_of_albums);
    i := 0;
    for artist_name: library.artist_names_sorted {
        artist_ptr := table_find_pointer(library.artists, artist_name);
        assert(artist_ptr != null, "Failed to find artist '%' in table when loading library album art data", artist_name);

        for album_name: artist_ptr.album_names_sorted_by_date {
            album_ptr := table_find_pointer(artist_ptr.albums, album_name);
            assert(album_ptr != null, "Failed to find album '%' - '%' in table when loading library album art data", artist_name, album_name);

            library_album_art.albums[i] = album_ptr;
            i += 1;
        }
    }
}

library_album_art_event_loop :: (frame: u64, header_bottom: int) {

    Y_PADDING_BELOW_HEADER := Y_MARGIN_SIZE;

    texture_width  : s32 = 200;
    texture_height : s32 = texture_width;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - 2 * Y_MARGIN_SIZE;
    rows := total_height / texture_height - 1;

    total_width := cast(s32)display_width();
    columns := total_width / texture_width - 1;

    library_album_art_move_cursor_down :: () #expand {
        `library_album_art_cursor.position += ifx `library_album_art_cursor.position > (library_album_art.albums.count - columns - 1) then 0 else columns;
    }
    library_album_art_move_cursor_up :: () #expand {
        `library_album_art_cursor.position -= ifx `library_album_art_cursor.position < columns then 0 else columns;
    }

    library_album_art_move_cursor_left :: () #expand {
        `library_album_art_cursor.position -= 1;
    }
    library_album_art_move_cursor_right :: () #expand {
        `library_album_art_cursor.position += 1;
    }

    library_album_art_move_cursor_one_page_down :: () #expand {
        `library_album_art_cursor.position += rows * columns;
    }
    library_album_art_move_cursor_one_page_up :: () #expand {
        `library_album_art_cursor.position -= rows * columns;
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

                  case KEY_G;
                    if it.shift_pressed {
                        library_album_art_cursor.position = library_album_art.albums.count - 1;
                    } else {
                        library_album_art_cursor.position = 0;
                    }
                    break it;

                  case KEY_D;
                    if it.ctrl_pressed {
                        table_set(*library_album_art_key_pressed_on_frame, .CTRL_D, frame);
                        last_library_album_art_key_pressed = .CTRL_D;
                        library_album_art_move_cursor_one_page_down();
                    }
                    break it;
                  case KEY_U;
                    if it.ctrl_pressed {
                        table_set(*library_album_art_key_pressed_on_frame, .CTRL_U, frame);
                        last_library_album_art_key_pressed = .CTRL_U;
                        library_album_art_move_cursor_one_page_up();
                    }
                    break it;

                  case KEY_O;
                    handle_mpd_idle_events();

                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("Getting current song");
                    if !mpd_current_song break;
                    uri := to_string(MPD.song_get_uri(mpd_current_song));
                    for album, album_index: library_album_art.albums {
                        for song: album.songs {
                            if song.uri == uri {
                                library_album_art_cursor.position = album_index;
                                break;
                            }
                        }
                    }
                    break it;

                  case KEY_R;
                    album_index := library_album_art_cursor.position;
                    album := library_album_art.albums[album_index];
                    album.art_texture = load_thumbnail_if_exists(album_index);

                  case .ENTER;
                    last_library_album_art_key_pressed = .ENTER;
                    table_set(*library_album_art_key_pressed_on_frame, .ENTER, frame);
                    album := library_album_art.albums[library_album_art_cursor.position];
                    song_id_to_play := add_album_to_queue(album.artist_name, album.name);
                    if song_id_to_play >= 0 {
                        assert(mpd_connection != null);
                        MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                        handle_errors("Playing first song in group added to queue");
                        update_status();
                    }
                    break it;

                  case .SPACEBAR;
                    last_library_album_art_key_pressed = .SPACE;
                    table_set(*library_album_art_key_pressed_on_frame, .SPACE, frame);
                    album := library_album_art.albums[library_album_art_cursor.position];
                    add_album_to_queue(album.artist_name, album.name);
                    break it;

                  // case;
                    // print("key_code: %\n", it.key_code);
                }
            }

        }
    }

    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .J)       library_album_art_move_cursor_down();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .K)       library_album_art_move_cursor_up();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .H)       library_album_art_move_cursor_left();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .L)       library_album_art_move_cursor_right();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .CTRL_D)  library_album_art_move_cursor_one_page_down();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .CTRL_U)  library_album_art_move_cursor_one_page_up();

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

            index_of_first_album_in_row := library_album_art_cursor.position / columns * columns;
            album_index: s64 = 0;
            if index_of_first_album_in_row > library_album_art.albums.count - 3 * columns {
                album_index = library_album_art.albums.count - 3 * columns;
            } else if index_of_first_album_in_row > columns {
                album_index = index_of_first_album_in_row - columns;
            }

            while entries_to_draw.count < max_entries_to_draw {
                album := library_album_art.albums[album_index];

                entry: Entry;
                entry.artist_name = album.artist_name;
                entry.album_name  = album.name;
                // TODO: thumbnail won't be in temporary storage, may not be freed correctly
                // if !album.art_texture && !album.tried_to_load_thumbnail {
                if !album.art_texture {
                    album.art_texture = load_thumbnail_if_exists(album_index);
                    // album.tried_to_load_thumbnail = true;
                }
                entry.texture = album.art_texture;
                entry.selected = album_index == library_album_art_cursor.position;

                array_add(*entries_to_draw, entry);

                album_index += 1;
                if album_index == library_album_art.albums.count {
                    break;
                }
            }
        }

        {
            HORIZONTAL_PADDING := (total_width  - columns * texture_width) / (columns - 1);
            VERTICAL_PADDING   := (total_height - rows    * texture_height) / (rows - 1);

            x := cast(float)X_MARGIN_SIZE;
            y := cast(float)header_bottom - Y_PADDING_BELOW_HEADER;

            row, column := 0;
            for entry: entries_to_draw {

                if entry.selected {
                    SELECTED_COVER_HIGHLIGHT_WIDTH :: 8;
                    for i: 0..SELECTED_COVER_HIGHLIGHT_WIDTH {
                        c := 1.0 - i / cast(float)SELECTED_COVER_HIGHLIGHT_WIDTH;
                        width := SELECTED_COVER_HIGHLIGHT_WIDTH - i + 4;
                        Simp.set_shader_for_color();
                        Simp.immediate_quad(
                            cast(float)x - width,
                            cast(float)y + width,
                            cast(float)x + texture_width + width,
                            cast(float)y - texture_width - width,
                            rgba(c,c,c,1)
                        );
                    }
                }

                if entry.texture {
                    Simp.set_shader_for_images(entry.texture);
                    Simp.immediate_begin();
                    Simp.immediate_quad(xy(x, y - texture_height), xy(x + texture_width, y - texture_height), xy(x + texture_width, y), xy(x, y));
                    Simp.immediate_flush();
                } else {
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)x, cast(float)y, cast(float)x + texture_width, cast(float)y - texture_width, rgba(0,0,0,1));
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

THUMBNAIL_WIDTH :: 200;

#import "System";
#import "Thread";
#import "Pool";

album_art_creation_thread_group: Thread_Group;

pool: Pool;

Thumbnail_Job_Info :: struct {
    artist          : string;
    album           : string;
    album_directory : string;
    success         : bool;
}

start_album_art_creation_thread_group :: () -> int {

    init_thread_group :: () {
        num_cpus := get_number_of_processors();
        #if (OS == .WINDOWS) || (OS == .LINUX) {
            // This routine reports hyperthreads, so, divide by two, because of Intel marketing.
            num_cpus /= 2;
        }
        num_threads := max(num_cpus - 1, 1);
        log("This machine reports % CPUs; starting % threads.\n", num_cpus, num_threads);

        init(*album_art_creation_thread_group, num_threads, thread_proc);

        album_art_creation_thread_group.name = "Create album art thumbnails";
        album_art_creation_thread_group.logging = false;
    }

    thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
        thumbnail_info := cast(*Thumbnail_Job_Info) work;
        if !create_album_art_thumbnail(thumbnail_info.artist, thumbnail_info.album, thumbnail_info.album_directory) {
            log("Failed to create album art thumbnail for % - %", thumbnail_info.artist, thumbnail_info.album);
            thumbnail_info.success = false;
        } else {
            thumbnail_info.success = true;
        }
        return .CONTINUE;
    }

    init_thread_group();
    start(*album_art_creation_thread_group);

    thread_proc_context: Context;
    thread_proc_context.allocator.proc = pool_allocator_proc;
    thread_proc_context.allocator.data = *pool;

    set_allocators(*pool);

    num_thumbnails_attempting_to_create := 0;
    for album: library_album_art.albums {
        thumbnail_filename := tprint("%-%x.bmp", get_hash(tprint("%-%", album.artist_name, album.name)), THUMBNAIL_WIDTH);
        uri := album.songs[0].uri;
        thumbnail_path := tprint("/home/grish/src/jai/jai-mpd/.thumbnails/%", thumbnail_filename);

        if !file_exists(thumbnail_path) {
            push_context thread_proc_context {
                work := New(Thumbnail_Job_Info);
                work.artist          = album.artist_name;
                work.album           = album.name;
                work.album_directory = path_strip_filename(uri);

                add_work(*album_art_creation_thread_group, work, tprint("Work item for % - %", album.artist_name, album.name));
                num_thumbnails_attempting_to_create += 1;
            }
        }
    }

    return num_thumbnails_attempting_to_create;
}

MPD_LIBRARY_DIRECTORY :: "/home/grish/media/music/library";
create_album_art_thumbnail :: (artist: string, album: string, album_directory: string) -> bool {

    cover_path: string;
    for cover_name: string.["cover.jpg", "cover.png"] {
        // TODO: get library path from mpd and pass into this thread UPDATE: unless libmpdclient doesn't provide that??
        path := tprint("%/%2%3", MPD_LIBRARY_DIRECTORY, album_directory, cover_name);
        print("path: %\n", path);
        if file_exists(path) {
            cover_path = path;
        }
    }
    if cover_path == "" return false;

    thumbnail_filename := tprint("%-%x.bmp", get_hash(tprint("%-%", artist, album)), THUMBNAIL_WIDTH);
    thumbnail_path := tprint("/home/grish/src/jai/jai-mpd/.thumbnails/%", thumbnail_filename);

    log("Attempting to load cover at path %\n", cover_path);

    // load the raw data into a bitmap
    bitmap: Simp.Bitmap;
    defer Simp.deinit(*bitmap);
    if !Simp.bitmap_load(*bitmap, cover_path) {
        log("Failed to load album art file %", cover_path, flags=.ERROR);
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

load_thumbnail_if_exists :: (album_index: s64) -> *Simp.Texture {

    album := library_album_art.albums[album_index];

    thumbnail_filename := tprint("%-%x.bmp", get_hash(tprint("%-%", album.artist_name, album.name)), THUMBNAIL_WIDTH);
    uri := album.songs[0].uri;
    thumbnail_path := tprint("/home/grish/src/jai/jai-mpd/.thumbnails/%", thumbnail_filename);

    if !file_exists(thumbnail_path) {
        // log("Thumbnail not found for % - %", album.artist_name, album.name);
        return null;
    }

    texture := New(Simp.Texture);
    if !Simp.texture_load_from_file(texture, thumbnail_path) {
        log("Failed to load thumbnail for % - %", album.artist_name, album.name, flags=.ERROR);
        return null;
    }

    return texture;
}

BUFFER_MAX :: 8192;
load_album_art :: (mpd_connection: *MPD.connection, uri: string, data: *[..] u8) -> success: bool {
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
