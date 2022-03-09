#import "Hash_Table";
#import "Unicode";
#import "File_Utilities";
#import "Hash";
#import "File";

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

#load "album.jai";

SHOW_CURRENT_ALBUM := false;

library_album_art_event_loop :: (frame: u64, header_bottom: int) {

    Y_PADDING_BELOW_HEADER := Y_MARGIN_SIZE;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - 2 * Y_MARGIN_SIZE;
    rows := total_height / THUMBNAIL_SLOT_HEIGHT - 1;

    total_width := cast(s32)display_width();
    columns := total_width / THUMBNAIL_SLOT_WIDTH - 1;

    OLD_SHOW_CURRENT_ALBUM := SHOW_CURRENT_ALBUM;
    if SHOW_CURRENT_ALBUM {
        album_process_input(frame, library_album_art.albums[library_album_art_cursor.position]);
    } else {
        library_album_art_process_input(frame, rows, columns);
    }

    if SHOW_CURRENT_ALBUM {
        album_draw_one_frame(library_album_art.albums[library_album_art_cursor.position], !OLD_SHOW_CURRENT_ALBUM);
    } else {
        library_album_art_draw_one_frame(header_bottom, rows, columns, total_width, total_height, Y_PADDING_BELOW_HEADER);
    }
}

THUMBNAIL_SLOT_WIDTH  : s32 : 200;
THUMBNAIL_SLOT_HEIGHT : s32 : THUMBNAIL_SLOT_WIDTH;

library_album_art_process_input :: (frame: u64, rows: int, columns: int) {

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

                  // case KEY_R;
                  //   album_index := library_album_art_cursor.position;
                  //   album := library_album_art.albums[album_index];
                  //   album.thumbnail_texture = load_thumbnail_if_exists(album_index);

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

                  case KEY_I;
                    SHOW_CURRENT_ALBUM = true;
                    break it;

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
}

library_album_art_draw_one_frame :: (header_bottom: int, rows: int, columns: int, total_width: s32, total_height: int, Y_PADDING_BELOW_HEADER: s32) {

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

        album_index: s64 = 0;
        { // calculate index of first album to display
            index_of_first_album_in_current_row := library_album_art_cursor.position / columns * columns;
            index_of_first_album_on_last_page   := (library_album_art.albums.count - 1 - (rows - 1) * columns) / columns * columns;
            number_of_albums_in_half_page       := ((rows - 1) / 2) * columns;

            if index_of_first_album_in_current_row > index_of_first_album_on_last_page { // we're on the last page
                album_index = index_of_first_album_on_last_page;
            } else if index_of_first_album_in_current_row > number_of_albums_in_half_page { // we're on a column after the first but before the last page
                album_index = index_of_first_album_in_current_row - number_of_albums_in_half_page;
            }
        }

        max_characters_in_column := THUMBNAIL_SLOT_WIDTH / font.w_width;
        while entries_to_draw.count < max_entries_to_draw {
            album := library_album_art.albums[album_index];

            ellipsis :: u8.[226, 128, 166];

            entry: Entry;

            if album.artist_name.count > max_characters_in_column {
                entry.artist_name = alloc_string(max_characters_in_column + 2, __temporary_allocator);
                memcpy(entry.artist_name.data, album.artist_name.data, max_characters_in_column - 1);
                memcpy(entry.artist_name.data + max_characters_in_column - 1, ellipsis.data, ellipsis.count);
            } else {
                entry.artist_name = copy_temporary_string(slice(album.artist_name, 0, max_characters_in_column));
            }

            if album.name.count > max_characters_in_column {
                entry.album_name = alloc_string(max_characters_in_column + 2, __temporary_allocator);
                memcpy(entry.album_name.data, album.name.data, max_characters_in_column - 1);
                memcpy(entry.album_name.data + max_characters_in_column - 1, ellipsis.data, ellipsis.count);
            } else {
                entry.album_name = copy_temporary_string(slice(album.name, 0, max_characters_in_column));
            }

            if !album.thumbnail_texture {
                album.thumbnail_texture = load_thumbnail_if_exists(album_index);
            }
            entry.texture  = album.thumbnail_texture;
            entry.selected = album_index == library_album_art_cursor.position;

            array_add(*entries_to_draw, entry);

            album_index += 1;
            if album_index == library_album_art.albums.count {
                break;
            }
        }
    }

    {
        TEXT_PADDING_Y :: 5;
        SELECTED_COVER_HIGHLIGHT_WIDTH :: 8;
        HORIZONTAL_PADDING := cast(s32) ((total_width  - columns * THUMBNAIL_SLOT_WIDTH) / (columns - 1));
        VERTICAL_PADDING   := cast(s32) ((total_height - rows * (THUMBNAIL_SLOT_HEIGHT + 2 * (font.character_height + TEXT_PADDING_Y + SELECTED_COVER_HIGHLIGHT_WIDTH))) / (rows - 1));

        x := X_MARGIN_SIZE;
        y := header_bottom - Y_PADDING_BELOW_HEADER;

        row, column := 0;
        for entry: entries_to_draw {

            { // album name
                text_width := Simp.prepare_text(font, entry.album_name);
                text_x := x + THUMBNAIL_SLOT_WIDTH / 2 - text_width / 2;
                text_y := y - THUMBNAIL_SLOT_HEIGHT - SELECTED_COVER_HIGHLIGHT_WIDTH - (TEXT_PADDING_Y + font.character_height);

                if entry.selected {
                    rectangle_width := THUMBNAIL_SLOT_WIDTH;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)text_x - 10, cast(float)text_y - 5, cast(float)text_x + text_width + 10, cast(float)text_y + font.character_height, rgba(1,1,1,1));
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                } else {
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                }
            }
            { // artist name
                text_width := Simp.prepare_text(font, entry.artist_name);
                text_x := x + THUMBNAIL_SLOT_WIDTH / 2 - text_width / 2;
                text_y := y - THUMBNAIL_SLOT_HEIGHT - SELECTED_COVER_HIGHLIGHT_WIDTH - 2 * (TEXT_PADDING_Y + font.character_height);

                if entry.selected {
                    rectangle_width := THUMBNAIL_SLOT_WIDTH;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)text_x - 10, cast(float)text_y - 5, cast(float)text_x + text_width + 10, cast(float)text_y + font.character_height, rgba(1,1,1,1));
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                } else {
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                }
            }

            if entry.selected {
                for i: 0..SELECTED_COVER_HIGHLIGHT_WIDTH {
                    c := 1.0 - i / cast(float)SELECTED_COVER_HIGHLIGHT_WIDTH;
                    width := SELECTED_COVER_HIGHLIGHT_WIDTH - i + 4;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(
                        cast(float)x - width,
                        cast(float)y + width,
                        cast(float)x + THUMBNAIL_SLOT_WIDTH + width,
                        cast(float)y - THUMBNAIL_SLOT_HEIGHT - width,
                        rgba(c,c,c,1)
                    );
                }
                Simp.set_shader_for_color();
            }

            if entry.texture {
                Simp.set_shader_for_images(entry.texture);
                Simp.immediate_begin();
                // scale the display height of the cover
                cover_display_height := min(cast(float)THUMBNAIL_SLOT_HEIGHT, cast(float)THUMBNAIL_SLOT_WIDTH * cast(float)entry.texture.height/entry.texture.width);
                height_difference := THUMBNAIL_SLOT_HEIGHT - cover_display_height;
                Simp.immediate_quad(
                    xy(cast(float)x, cast(float)y - THUMBNAIL_SLOT_HEIGHT + height_difference / 2),
                    xy(cast(float)x + THUMBNAIL_SLOT_WIDTH, cast(float)y - THUMBNAIL_SLOT_HEIGHT + height_difference / 2),
                    xy(cast(float)x + THUMBNAIL_SLOT_WIDTH, cast(float)y - height_difference / 2),
                    xy(cast(float)x, cast(float)y - height_difference / 2)
                );
                Simp.immediate_flush();

            } else {
                Simp.set_shader_for_color();
                Simp.immediate_quad(cast(float)x, cast(float)y, cast(float)x + THUMBNAIL_SLOT_WIDTH, cast(float)y - THUMBNAIL_SLOT_WIDTH, rgba(0,0,0,1));
            }

            column += 1;
            if column == columns {
                row += 1;
                column = 0;
                x = X_MARGIN_SIZE;
                y -= THUMBNAIL_SLOT_HEIGHT + SELECTED_COVER_HIGHLIGHT_WIDTH + 2 * (TEXT_PADDING_Y + font.character_height);
                y -= VERTICAL_PADDING;
            } else {
                x += THUMBNAIL_SLOT_WIDTH;
                x += HORIZONTAL_PADDING;
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

Bitmap_Job_Info :: struct {
    cover_path          : string;
    thumbnail_path      : string;

    create_thumbnail    : bool = false;
    thumbnail_width     : s32;
    thumbnail_success   : bool;

    create_display_art  : bool = false;
    display_art_path    : string;
    display_art_width   : s32;
    display_art_success : bool;

    // load_thumbnail         : bool = false;
    artist_name            : string;
    album_name             : string;
    thumbnail_bitmap       : *Simp.Bitmap;
    thumbnail_load_success : bool;
}

THUMBNAIL_DIRECTORY :: "/home/grish/src/jai/jai-mpd/.thumbnails";

start_album_art_creation_thread_group :: () -> int {

    init_thread_group :: (num_jobs: s32) {
        num_cpus := get_number_of_processors();
        #if (OS == .WINDOWS) || (OS == .LINUX) {
            // This routine reports hyperthreads, so, divide by two, because of Intel marketing.
            num_cpus /= 2;
        }
        num_threads := min(num_jobs, max(num_cpus - 1, 1));
        log("This machine reports % CPUs for % job(s); starting % threads.\n", num_cpus, num_jobs, num_threads);

        init(*album_art_creation_thread_group, num_threads, thread_proc);

        album_art_creation_thread_group.name = "Create album art thumbnails";
        album_art_creation_thread_group.logging = false;
    }

    thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
        job_info := cast(*Bitmap_Job_Info) work;

        log("Attempting to load cover at path %\n", job_info.cover_path);

        // load the raw data into a bitmap
        bitmap := New(Simp.Bitmap);
        defer { Simp.deinit(bitmap); free(bitmap); };
        if !Simp.bitmap_load(bitmap, job_info.cover_path) {
            log("Failed to load album art file %", job_info.cover_path, flags=.ERROR);
            return .CONTINUE;
        }

        if job_info.create_thumbnail {
            if !resize_and_save_bitmap(bitmap, job_info.thumbnail_path, job_info.thumbnail_width) {
                log("Failed to convert cover % to thumbnail at %", job_info.cover_path, job_info.thumbnail_path);
                job_info.thumbnail_success = false;
            } else {
                job_info.thumbnail_success = true;
            }
        }
        if job_info.create_display_art {
            if !resize_and_save_bitmap(bitmap, job_info.display_art_path, job_info.display_art_width) {
                log("Failed to convert cover % to display art bitmap at %", job_info.cover_path, job_info.display_art_path);
                job_info.display_art_success = false;
            } else {
                job_info.display_art_success = true;
            }
        }

        if file_exists(job_info.thumbnail_path) {
            log("loading thumbnail at path %", job_info.thumbnail_path);

            artist_ptr := table_find_pointer(library.artists, job_info.artist_name);
            assert(artist_ptr != null);
            album_ptr := table_find_pointer(artist_ptr.albums, job_info.album_name);
            assert(album_ptr != null);

            thumbnail_file, success := file_open(job_info.thumbnail_path);
            if !success {
                log("Could not open thumbnail file %", job_info.thumbnail_path);
                return .CONTINUE;
            }
            defer file_close(*thumbnail_file);

            length := file_length(thumbnail_file);
            buffer := cast(*u8) alloc(length);

            success = file_read(thumbnail_file, buffer, length);
            if !success {
                log("Could not read thumbnail file %\n", job_info.thumbnail_path);
                free(buffer);
                return .CONTINUE;
            }

            album_ptr.thumbnail_data.data  = buffer;
            album_ptr.thumbnail_data.count = length;
            job_info.thumbnail_load_success = true;

            // job_info.thumbnail_bitmap = New(Simp.Bitmap);
            // if !Simp.bitmap_load(job_info.thumbnail_bitmap, job_info.thumbnail_path) {

            // if !Simp.texture_load_from_file(album_ptr.thumbnail_texture, job_info.thumbnail_path) {
                // log("Failed to load thumbnail for % - %", job_info.artist_name, job_info.album_name, flags=.ERROR);
                // Simp.deinit(job_info.thumbnail_bitmap);
                // free(album_ptr.thumbnail_texture);
                // job_info.thumbnail_load_success = false;
            // } else {
                // job_info.thumbnail_load_success = true;
            // }
        }

        return .CONTINUE;
    }

    set_allocators(*pool);
    thread_proc_context: Context;
    thread_proc_context.allocator.proc = pool_allocator_proc;
    thread_proc_context.allocator.data = *pool;

    print("pool: %\n", *pool);
    work_list: [..] *Bitmap_Job_Info;

    num_thumbnails_attempting_to_create := 0;
    push_context thread_proc_context {
        for album: library_album_art.albums { // find all albums that don't have a thumbnail but do have a cover we can use to create one
            if album.cover_path && file_exists(album.cover_path) {
                album_hash := get_hash(tprint("%-%", album.artist_name, album.name));
                thumbnail_path := tprint("%/%-%x.bmp", THUMBNAIL_DIRECTORY, album_hash, THUMBNAIL_WIDTH);
                display_art_path := tprint("%/%-%x.bmp", THUMBNAIL_DIRECTORY, album_hash, COVER_DISPLAY_WIDTH);

                work := New(Bitmap_Job_Info);
                work.artist_name    = copy_string(album.artist_name);
                work.album_name     = copy_string(album.name);
                work.cover_path     = copy_string(album.cover_path);
                work.thumbnail_path = copy_string(thumbnail_path);
                if !file_exists(thumbnail_path) {
                    work.create_thumbnail = true;
                    work.thumbnail_width  = THUMBNAIL_WIDTH;
                }
                if !file_exists(display_art_path) {
                    work.create_display_art = true;
                    work.display_art_path   = copy_string(display_art_path);
                    work.display_art_width  = COVER_DISPLAY_WIDTH;
                }
                array_add(*work_list, work);
            }
        }

    }

    if work_list.count > 0 { // only start threads if we have any work to do
        init_thread_group(cast(s32)work_list.count);
        start(*album_art_creation_thread_group);

        for work_list {
            add_work(*album_art_creation_thread_group, it, tprint("Work item to create thumbnail from cover at %", it.cover_path));
        }
    }
    array_free(work_list);


    return work_list.count;
}

MPD_LIBRARY_DIRECTORY :: "/home/grish/media/music/library";

resize_and_save_bitmap :: (bitmap: *Simp.Bitmap, output_path: string, width: s32) -> bool {
    // resize to bitmap size
    resized_bitmap := New(Simp.Bitmap);
    Simp.bitmap_resize(bitmap, width, cast(s32)(bitmap.height * cast(float64)width / bitmap.width), resized_bitmap);
    defer { Simp.deinit(resized_bitmap); free(resized_bitmap); };

    // save the bitmap
    if !Simp.bitmap_save(resized_bitmap, output_path) {
        log("Failed to save resized album art bitmap to '%'", output_path, flags=.ERROR);
        return false;
    }

    log("Saved resized album art bitmap to '%'", output_path);

    return true;
}

load_thumbnail_if_exists :: (album_index: s64) -> *Simp.Texture {

    album := library_album_art.albums[album_index];
    if !album.thumbnail_data {
        return null;
    }
    defer array_free(album.thumbnail_data);

    texture := New(Simp.Texture);
    if !Simp.texture_load_from_memory(texture, album.thumbnail_data) {
        free(texture);
        log("Failed to load thumbnail from memory for % - %", album.artist_name, album.name);
        return null;
    }

    // thumbnail_path := tprint("%/%-%x.bmp", THUMBNAIL_DIRECTORY, get_hash(tprint("%-%", album.artist_name, album.name)), THUMBNAIL_WIDTH);
    // if !file_exists(thumbnail_path) {
    //     // log("Thumbnail not found for % - %", album.artist_name, album.name);
    //     return null;
    // }

    // texture := New(Simp.Texture);
    // if !Simp.texture_load_from_file(texture, thumbnail_path) {
    //     log("Failed to load thumbnail for % - %", album.artist_name, album.name, flags=.ERROR);
    //     return null;
    // }

    return texture;
}
