Queue_Cursor :: struct {
    position := 0;
}

queue_cursor: Queue_Cursor;

queue_columns: [4] [..] string;

queue: struct {
    songs: [..] Song;
    version: u32;
}

load_queue :: () {

    handle_mpd_idle_events();

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    if !status { print("Status is null, not refreshing queue\n"); return; }
    mpd_queue_length := MPD.status_get_queue_length(status);
    queue.version = MPD.status_get_queue_version(status);
    MPD.status_free(status);

    // reserve the space but don't resize the array, in case we're missing metadata
    // for any songs while we're iterating below
    array_reserve(*queue.songs, mpd_queue_length);

    assert(mpd_connection != null);
    MPD.send_list_queue_meta(mpd_connection);
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);

            song: Song;
            song.track  = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK       , 0));
            song.artist = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0));
            song.album  = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM       , 0));
            song.name   = copy_from_c_string(MPD.song_get_tag(mpd_song, .TITLE       , 0));
            song.uri    = copy_from_c_string(MPD.song_get_uri(mpd_song));

            array_add(*queue.songs, song);
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    // TODO: should we un-reserve the unused space in the array here?

    array_reset(*queue_columns[0]);
    array_reset(*queue_columns[1]);
    array_reset(*queue_columns[2]);
    array_reset(*queue_columns[3]);

    array_resize(*queue_columns[0], queue.songs.count);
    array_resize(*queue_columns[1], queue.songs.count);
    array_resize(*queue_columns[2], queue.songs.count);
    array_resize(*queue_columns[3], queue.songs.count);

    for song: queue.songs {
        queue_columns[0][it_index] = song.name;
        queue_columns[1][it_index] = song.album;
        queue_columns[2][it_index] = song.artist;
        queue_columns[3][it_index] = "0:00";
    }
}

load_queue_changes :: () {

    handle_mpd_idle_events();

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    // TODO: this check is okay to make but is also mainly a workaround for the mpd connection dying bug
    if !status { print("Status is null, not refreshing queue\n"); return; }
    mpd_queue_length := MPD.status_get_queue_length(status);

    old_version := queue.version;
    queue.version = MPD.status_get_queue_version(status);

    MPD.status_free(status);

    assert(mpd_connection != null);
    MPD.send_queue_changes_meta(mpd_connection, old_version);
    handle_errors("Retrieving MPD metadata");

    mpd_song := MPD.recv_song(mpd_connection);
    handle_errors("Receiving first updated queue song");

    while mpd_song {
        queue_song_position := MPD.song_get_pos(mpd_song);
        mpd_artist := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
        mpd_album  := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
        mpd_title  := MPD.song_get_tag(mpd_song, .TITLE       , 0);
        mpd_date   := MPD.song_get_tag(mpd_song, .DATE        , 0);

        song: Song;
        song.track  = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK       , 0));
        song.artist = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0));
        song.album  = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM       , 0));
        song.name   = copy_from_c_string(MPD.song_get_tag(mpd_song, .TITLE       , 0));
        song.uri    = copy_from_c_string(MPD.song_get_uri(mpd_song));

        if queue_song_position < queue.songs.count {
            free(queue.songs[queue_song_position]);
            queue.songs[queue_song_position] = song;
        } else {
            array_add(*queue.songs, song);
        }

        MPD.song_free(mpd_song);
        mpd_song = MPD.recv_song(mpd_connection);
        handle_errors("Receiving updated queue song");
    }

    for i: mpd_queue_length..(queue.songs.count - 1) {
        free(queue.songs[i]);
    }
    array_resize(*queue.songs, mpd_queue_length);

    array_reset(*queue_columns[0]);
    array_reset(*queue_columns[1]);
    array_reset(*queue_columns[2]);
    array_reset(*queue_columns[3]);

    array_resize(*queue_columns[0], queue.songs.count);
    array_resize(*queue_columns[1], queue.songs.count);
    array_resize(*queue_columns[2], queue.songs.count);
    array_resize(*queue_columns[3], queue.songs.count);

    for song: queue.songs {
        queue_columns[0][it_index] = song.name;
        queue_columns[1][it_index] = song.album;
        queue_columns[2][it_index] = song.artist;
        queue_columns[3][it_index] = "0:00";
    }
}

last_queue_key_pressed: Key;
queue_key_pressed_on_frame: Table(Key, u64);

queue_init_repeatable_keys :: () {
    table_set(*queue_key_pressed_on_frame, .J,       0);
    table_set(*queue_key_pressed_on_frame, .K,       0);
    table_set(*queue_key_pressed_on_frame, .SHIFT_J, 0);
    table_set(*queue_key_pressed_on_frame, .SHIFT_K, 0);
    table_set(*queue_key_pressed_on_frame, .D,       0);
    table_set(*queue_key_pressed_on_frame, .U,       0);
    table_set(*queue_key_pressed_on_frame, .X,       0);
    table_set(*queue_key_pressed_on_frame, .ENTER,   0);
}

queue_event_loop :: (frame: u64) {

    new_cursor: Queue_Cursor;
    new_cursor.position = queue_cursor.position;

    queue_shift_selected_item_down :: () #expand {
        if queue_cursor.position < queue.songs.count - 1 {
            MPD.run_swap(`mpd_connection, cast(u32)queue_cursor.position, cast(u32)queue_cursor.position + 1);
            handle_errors("Moving song down in queue");
            load_queue_changes();
            `new_cursor.position += 1;
        }
    }
    queue_move_cursor_down :: () #expand {
        `new_cursor.position += 1;
    }

    queue_shift_selected_item_up :: () #expand {
        if queue_cursor.position > 0 {
            MPD.run_swap(mpd_connection, cast(u32)queue_cursor.position, cast(u32)queue_cursor.position - 1);
            handle_errors("Moving song up in queue");
            load_queue_changes();
            `new_cursor.position -= 1;
        }
    }
    queue_move_cursor_up :: () #expand {
        `new_cursor.position -= 1;
    }

    queue_move_cursor_one_page_down :: () #expand {
        `new_cursor.position += ITEMS_IN_PAGE;
    }
    queue_move_cursor_one_page_up :: () #expand {
        `new_cursor.position -= ITEMS_IN_PAGE;
    }

    queue_remove_selected_song :: () #expand {
        if queue_cursor.position >= 0 && queue_cursor.position <= queue.songs.count {
            handle_mpd_idle_events();
            MPD.run_delete(mpd_connection, cast(u32)queue_cursor.position);
            handle_errors("Removing song from queue");
            load_queue_changes();
            update_status(false);
        }
    }

    queue_play_selected_song :: () #expand {
        handle_mpd_idle_events();
        MPD.run_play_pos(mpd_connection, cast(u32)queue_cursor.position);
        handle_errors("Playing queue song");
        update_status(false);
    }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    if it.shift_pressed {
                        table_set(*queue_key_pressed_on_frame, .SHIFT_J, frame);
                        last_queue_key_pressed = .SHIFT_J;
                        queue_shift_selected_item_down();
                    } else {
                        table_set(*queue_key_pressed_on_frame, .J, frame);
                        last_queue_key_pressed = .J;
                        queue_move_cursor_down();
                    }
                    break it;
                  case KEY_K;
                    if it.shift_pressed {
                        table_set(*queue_key_pressed_on_frame, .SHIFT_K, frame);
                        last_queue_key_pressed = .SHIFT_K;
                        queue_shift_selected_item_up();
                    } else {
                        table_set(*queue_key_pressed_on_frame, .K, frame);
                        last_queue_key_pressed = .K;
                        queue_move_cursor_up();
                    }
                    break it;

                  case KEY_D;
                    table_set(*queue_key_pressed_on_frame, .D, frame);
                    last_queue_key_pressed = .D;
                    queue_move_cursor_one_page_down();
                    break it;
                  case KEY_U;
                    table_set(*queue_key_pressed_on_frame, .U, frame);
                    last_queue_key_pressed = .U;
                    queue_move_cursor_one_page_up();
                    break it;

                  case KEY_G;
                    if it.shift_pressed {
                        new_cursor.position = queue.songs.count - 1;
                    } else {
                        new_cursor.position = 0;
                    }
                    break it;

                  case KEY_X;
                    table_set(*queue_key_pressed_on_frame, .X, frame);
                    last_queue_key_pressed = .X;
                    queue_remove_selected_song();
                    break it;

                  case KEY_O; // move cursor to currently playing song
                    handle_mpd_idle_events();
                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("Getting current song");
                    if !mpd_current_song break;
                    uri := to_string(MPD.song_get_uri(mpd_current_song));

                    for song: queue.songs {
                        if song.uri == uri {
                            new_cursor.position = it_index;
                        }
                    }
                    break it;

                  case .ENTER; // play selected song
                    table_set(*queue_key_pressed_on_frame, .ENTER, frame);
                    last_queue_key_pressed = .ENTER;
                    queue_play_selected_song();
                    break it;

                  // case;
                    // print("key_code: %\n", it.key_code);
                }
            }

        }
    }

    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .J)       queue_move_cursor_down();
    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .K)       queue_move_cursor_up();
    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .SHIFT_J) queue_shift_selected_item_down();
    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .SHIFT_K) queue_shift_selected_item_up();
    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .D)       queue_move_cursor_one_page_down();
    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .U)       queue_move_cursor_one_page_up();
    if key_held_passed_threshold(queue_key_pressed_on_frame, last_queue_key_pressed, frame, .X)       queue_remove_selected_song();

    if new_cursor.position < 0                       new_cursor.position = 0;
    if new_cursor.position >= queue_columns[0].count new_cursor.position = queue_columns[0].count - 1;

    queue_cursor = new_cursor;
    draw_queue_frame();
}

draw_queue_frame :: () {

    column_widths: [4] s32;
    column_widths[0] = cast(s32)(8 / 20.0 * display_width);
    column_widths[1] = cast(s32)(5 / 20.0 * display_width);
    column_widths[2] = cast(s32)(5 / 20.0 * display_width);
    column_widths[3] = cast(s32)(2 / 20.0 * display_width);

    original_y := HEADER_BOTTOM - 25;
    text_padding_y :: 5;

    index_start := max(0, min(queue_columns[0].count - ITEMS_IN_PAGE + 1, queue_cursor.position - ITEMS_IN_PAGE/ 2 + 1));
    index_end := min(index_start + ITEMS_IN_PAGE, queue_columns[0].count - 1);

    x := x_margin_size;
    {
        y := original_y;
        max_characters_in_column := (column_widths[0] - 100) / font.em_width;

        for i: index_start..index_end {
            song_name := queue_columns[0][i];

            text := slice(song_name, 0, max_characters_in_column);
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(1,1,1,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[0], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_widths[0];
    {
        y := original_y;
        max_characters_in_column := (column_widths[1] - 100) / font.em_width;

        for i: index_start..index_end {
            album := queue_columns[1][i];

            text := slice(album, 0, max_characters_in_column);
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[1], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_widths[1];
    {
        y := original_y;
        max_characters_in_column := (column_widths[2] - 100) / font.em_width;

        for i: index_start..index_end {
            artist := queue_columns[2][i];

            text := slice(artist, 0, max_characters_in_column);
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[2], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_widths[2];
    {
        y := original_y;
        max_characters_in_column := (column_widths[3] - 20) / font.em_width;

        for i: index_start..index_end {
            song_length := queue_columns[3][i];
            display_song_length := left_pad(slice(song_length, 0, max_characters_in_column), #char " ", max_characters_in_column);
            text := left_pad(slice(display_song_length, 0, max_characters_in_column), #char " ", max_characters_in_column);
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[3], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }
}
