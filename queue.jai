Queue_Cursor :: struct {
    position := 0;
}

queue_cursor: Queue_Cursor;

queue_columns: [4] [..] string;

queue: [..] Song;

load_queue :: () {

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    mpd_queue_length := MPD.status_get_queue_length(status);

    // array_resize(*queue, mpd_queue_length);

    for queue free(it);
    array_reset(*queue);
    array_reserve(*queue, mpd_queue_length);

    assert(mpd_connection != null);
    MPD.send_list_queue_meta(mpd_connection);
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");

    // queue_index := 0;
    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);

            mpd_artist := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
            mpd_album  := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
            mpd_title  := MPD.song_get_tag(mpd_song, .TITLE       , 0);
            mpd_date   := MPD.song_get_tag(mpd_song, .DATE        , 0);
            if mpd_artist && mpd_album && mpd_title {
                song: Song;

                song.track  = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK, 0));
                if !song.track { print("Have empty track\n"); continue; }

                song.artist = copy_from_c_string(mpd_artist);
                song.album  = copy_from_c_string(mpd_album);
                song.name   = copy_from_c_string(mpd_title);
                song.uri    = copy_from_c_string(MPD.song_get_uri(mpd_song));

                array_add(*queue, song);
            }
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    array_reset(*queue_columns[0]);
    array_reset(*queue_columns[1]);
    array_reset(*queue_columns[2]);
    array_reset(*queue_columns[3]);

    array_resize(*queue_columns[0], queue.count);
    array_resize(*queue_columns[1], queue.count);
    array_resize(*queue_columns[2], queue.count);
    array_resize(*queue_columns[3], queue.count);

    for song: queue {
        queue_columns[0][it_index] = song.name;
        queue_columns[1][it_index] = song.album;
        queue_columns[2][it_index] = song.artist;
        queue_columns[3][it_index] = "0:00";
    }
}

queue_last_key_pressed: Input.Key_Code;
queue_key_pressed_on_frame: Table(Input.Key_Code, u64);

queue_init_keys :: () {
    table_add(*queue_key_pressed_on_frame, KEY_J,                0);
    table_add(*queue_key_pressed_on_frame, KEY_K,                0);
    table_add(*queue_key_pressed_on_frame, KEY_D,                0);
    table_add(*queue_key_pressed_on_frame, KEY_U,                0);
    table_add(*queue_key_pressed_on_frame, KEY_X,                0);
    table_add(*queue_key_pressed_on_frame, .ENTER,               0);
    table_add(*queue_key_pressed_on_frame, KEY_B,                0);
    table_add(*queue_key_pressed_on_frame, KEY_F,                0);
    table_add(*queue_key_pressed_on_frame, .LEFT_ANGLE_BRACKET,  0);
    table_add(*queue_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, 0);
    table_add(*queue_key_pressed_on_frame, .EQUALS_SIGN,         0);
    table_add(*queue_key_pressed_on_frame, .DASH,                0);
}

queue_event_loop :: (frame: u64) {

    // if !idle MPD.send_idle(mpd_connection);
    // handle_errors("Putting MPD into idle mode");
    // idle = true;

    new_cursor: Queue_Cursor;
    new_cursor.position = queue_cursor.position;

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    table_set(*queue_key_pressed_on_frame, KEY_J, frame);
                    queue_last_key_pressed = KEY_J;
                    new_cursor.position += 1;
                  case KEY_K;
                    table_set(*queue_key_pressed_on_frame, KEY_K, frame);
                    queue_last_key_pressed = KEY_K;
                    new_cursor.position -= 1;

                  case KEY_D;
                    table_set(*queue_key_pressed_on_frame, KEY_D, frame);
                    queue_last_key_pressed = KEY_D;
                    new_cursor.position += ITEMS_IN_PAGE;
                  case KEY_U;
                    table_set(*queue_key_pressed_on_frame, KEY_U, frame);
                    queue_last_key_pressed = KEY_U;
                    new_cursor.position -= ITEMS_IN_PAGE;

                  case KEY_P;
                    handle_mpd_idle_events();
                    MPD.run_toggle_pause(mpd_connection);
                    handle_errors("");

                  case KEY_X;
                    table_set(*queue_key_pressed_on_frame, KEY_X, frame);
                    queue_last_key_pressed = KEY_X;
                    MPD.run_delete(mpd_connection, cast(u32)queue_cursor.position);
                    handle_errors("");
                    load_queue();

                  case KEY_C;
                    handle_mpd_idle_events();
                    MPD.run_clear(mpd_connection);
                    handle_errors("");
                    load_queue();

                  case KEY_O;
                    handle_mpd_idle_events();
                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("");
                    if !mpd_current_song break;
                    uri := to_string(MPD.song_get_uri(mpd_current_song));

                    for song: queue {
                        if song.uri == uri {
                            new_cursor.position = it_index;
                        }
                    }

                  case .ENTER;
                    table_set(*queue_key_pressed_on_frame, .ENTER, frame);
                    queue_last_key_pressed = .ENTER;
                    handle_mpd_idle_events();
                    MPD.run_play_pos(mpd_connection, cast(u32)queue_cursor.position);
                    handle_errors("");

                  case KEY_B;
                    table_set(*queue_key_pressed_on_frame, KEY_B, frame);
                    queue_last_key_pressed = KEY_B;
                    handle_mpd_idle_events();
                    MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
                    handle_errors("");
                  case KEY_F;
                    table_set(*queue_key_pressed_on_frame, KEY_F, frame);
                    queue_last_key_pressed = KEY_F;
                    handle_mpd_idle_events();
                    MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
                    handle_errors("");

                  case .LEFT_ANGLE_BRACKET;
                    table_set(*queue_key_pressed_on_frame, .LEFT_ANGLE_BRACKET, frame);
                    queue_last_key_pressed = .LEFT_ANGLE_BRACKET;
                    handle_mpd_idle_events();
                    MPD.run_previous(mpd_connection);
                    handle_errors("");
                  case .RIGHT_ANGLE_BRACKET;
                    table_set(*queue_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, frame);
                    queue_last_key_pressed = .RIGHT_ANGLE_BRACKET;
                    handle_mpd_idle_events();
                    MPD.run_next(mpd_connection);
                    handle_errors("");

                  case .EQUALS_SIGN;
                    table_set(*queue_key_pressed_on_frame, .EQUALS_SIGN, frame);
                    queue_last_key_pressed = .EQUALS_SIGN;
                    handle_mpd_idle_events();
                    MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
                    handle_errors("");
                  case .DASH;
                    table_set(*queue_key_pressed_on_frame, .DASH, frame);
                    queue_last_key_pressed = .DASH;
                    handle_mpd_idle_events();
                    MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                    handle_errors("");

                  // case;
                  //   print("key_code: %\n", it.key_code);
                }
            }

        }
    }

    // these will trigger when the corresponding key has been held down for at least 20 frames,
    // then will repeat the corresponding movement every 2 frames. the last press of the key
    // also has to be after the last press of its 'opposite' (J vs K, U vs D, - vs =).
    // this emulates how curses/terminal application new_cursor movement tends to behave

    KEY_HOLD_DELAY :: 20;


    if Input.input_button_states[KEY_J] & .DOWN    &&
       frame % 2                                   &&
       KEY_J == queue_last_key_pressed                   &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_J) + KEY_HOLD_DELAY
    {
        new_cursor.position += 1;
    } else
    if Input.input_button_states[KEY_K] & .DOWN    &&
       frame % 2                                   &&
       KEY_K == queue_last_key_pressed                   &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_K) + KEY_HOLD_DELAY
    {
        new_cursor.position -= 1;
    }

    if Input.input_button_states[KEY_D] & .DOWN    &&
       frame % 2                                   &&
       KEY_D == queue_last_key_pressed                   &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_D) + KEY_HOLD_DELAY
    {
        new_cursor.position += ITEMS_IN_PAGE;
    } else
    if Input.input_button_states[KEY_U] & .DOWN    &&
       frame % 2                                   &&
       KEY_U == queue_last_key_pressed                   &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_U) + KEY_HOLD_DELAY
    {
        new_cursor.position -= ITEMS_IN_PAGE;
    }

    if Input.input_button_states[Input.Key_Code.EQUALS_SIGN] & .DOWN &&
       frame % 2                                                     &&
       Input.Key_Code.EQUALS_SIGN == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, Input.Key_Code.EQUALS_SIGN) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
        handle_errors("");
    } else
    if Input.input_button_states[Input.Key_Code.DASH] & .DOWN &&
       frame % 2                                              &&
       Input.Key_Code.DASH == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, Input.Key_Code.DASH) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
        handle_errors("");
    }

    if Input.input_button_states[Input.Key_Code.LEFT_ANGLE_BRACKET] & .DOWN &&
       frame % 2                                                            &&
       Input.Key_Code.LEFT_ANGLE_BRACKET == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, Input.Key_Code.LEFT_ANGLE_BRACKET) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_previous(mpd_connection);
        handle_errors("");
    } else
    if Input.input_button_states[Input.Key_Code.RIGHT_ANGLE_BRACKET] & .DOWN &&
       frame % 2                                                             &&
       Input.Key_Code.RIGHT_ANGLE_BRACKET == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, Input.Key_Code.RIGHT_ANGLE_BRACKET) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_next(mpd_connection);
        handle_errors("");
    }

    if Input.input_button_states[KEY_B] & .DOWN &&
       frame % 2                                &&
       KEY_B == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_B) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
        handle_errors("");
    } else
    if Input.input_button_states[KEY_F] & .DOWN &&
       frame % 2                                &&
       KEY_F == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_F) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
        handle_errors("");
    }

    if Input.input_button_states[KEY_X] & .DOWN &&
       frame % 2                                &&
       KEY_X == queue_last_key_pressed          &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, KEY_X) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_delete(mpd_connection, cast(u32)queue_cursor.position);
        handle_errors("");
        load_queue();
    }

    if Input.input_button_states[Input.Key_Code.ENTER] & .DOWN &&
       frame % 2                                               &&
       Input.Key_Code.ENTER == queue_last_key_pressed                &&
       frame > <<table_find_pointer(queue_key_pressed_on_frame, Input.Key_Code.ENTER) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_play_pos(mpd_connection, cast(u32)queue_cursor.position);
        handle_errors("");
    }

    if new_cursor.position < 0                       new_cursor.position = 0;
    if new_cursor.position >= queue_columns[0].count new_cursor.position = queue_columns[0].count - 1;

    queue_cursor = new_cursor;
    draw_queue_frame();
}

// desktop
// window_width  : s32 : 2560;
// window_height : s32 : 1440;
// pixel_height := window_height / 96;
// column_width :: 700;
// ITEMS_IN_PAGE :: 50;

// laptop
// window_width  : s32 : 1920;
// window_height : s32 : 1080;
// pixel_height := window_height / 72;
// column_width := 600;
// ITEMS_IN_PAGE := 40;

// desktop - streaming
// window_width  : s32 : 1900;
// window_height : s32 : 1440;
// pixel_height := window_height / 48;
queue_column_widths :: int.[700, 400, 400, 200];
// ITEMS_IN_PAGE :: 30;

draw_queue_frame :: () {

    Simp.clear_render_target(0,0,0,1);

    total_column_width := 0; for queue_column_widths total_column_width += it;
    left_bound := cast(int) (window_width - total_column_width) / 2;
    original_y := cast(int) (window_height / 2 + ITEMS_IN_PAGE * (font.character_height + text_padding_y) / 2);
    text_padding_y :: 5;

    index_start := max(0, min(queue_columns[0].count - ITEMS_IN_PAGE + 1, queue_cursor.position - ITEMS_IN_PAGE/ 2 + 1));
    index_end := min(index_start + ITEMS_IN_PAGE, queue_columns[0].count - 1);

    x := left_bound;
    {
        y := original_y;
        max_characters_in_column := (queue_column_widths[0] - 100) / font.em_width;

        for i: index_start..index_end {
            song_name := queue_columns[0][i];

            width := Simp.prepare_text(font, slice(song_name, 0, max_characters_in_column));
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(1,1,1,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + queue_column_widths[0], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += queue_column_widths[0];
    {
        y := original_y;
        max_characters_in_column := (queue_column_widths[1] - 100) / font.em_width;

        for i: index_start..index_end {
            album := queue_columns[1][i];

            width := Simp.prepare_text(font, slice(album, 0, max_characters_in_column));
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + queue_column_widths[1], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += queue_column_widths[1];
    {
        y := original_y;
        max_characters_in_column := (queue_column_widths[2] - 100) / font.em_width;

        for i: index_start..index_end {
            artist := queue_columns[2][i];

            width := Simp.prepare_text(font, slice(artist, 0, max_characters_in_column));
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + queue_column_widths[2], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += queue_column_widths[2];
    {
        y := original_y;
        max_characters_in_column := (queue_column_widths[3] - 100) / font.em_width;

        for i: index_start..index_end {
            song_length := queue_columns[3][i];
            display_song_length := left_pad(slice(song_length, 0, max_characters_in_column), #char " ", max_characters_in_column);
            width := Simp.prepare_text(font, slice(display_song_length, 0, max_characters_in_column));
            if i == queue_cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + queue_column_widths[3], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    Simp.swap_buffers(window);
}
