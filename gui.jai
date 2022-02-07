#import "Basic";
#import "Math";
#import "String";
#import "Window_Creation";
#import "Hash_Table";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

KEY_B :: 66;
KEY_C :: 67;
KEY_D :: 68;
KEY_F :: 70;
KEY_H :: 72;
KEY_J :: 74;
KEY_K :: 75;
KEY_L :: 76;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_U :: 85;

// TODO: get NOW_PLAYING_URI on start from mpd (+ maybe always use mpd to set it)
NOW_PLAYING_URI: string;

window: Window_Type;

mpd_fd: s32;

Song :: struct {
    artist : string;
    album  : string;
    name   : string;
    track  : string;
    uri    : string;
}

left_pad :: (str: string, pad_char: u8, total_length: int) -> string {
    result := alloc_string(total_length, __temporary_allocator);
    pad_count := result.count - str.count;
    for 0..(pad_count - 1) result[it] = pad_char;
    memcpy(result.data + pad_count, str.data, str.count);
    return result;
}

right_pad :: (str: string, pad_char: u8, total_length: int) -> string {
    result := alloc_string(total_length, __temporary_allocator);
    memcpy(result.data, str.data, str.count);
    for str.count..(result.count - 1) result[it] = pad_char;
    return result;
}

Cursor :: struct {
    position := 0;
}

cursor: Cursor;

mpd_connection: *MPD.connection;
idle := false;

copy_from_c_string :: inline (s: *u8) -> string {
    return copy_string(to_string(s));
}

main :: () {

    init_fonts();

    window = create_window(window_width, window_height, "queue");
    Simp.set_render_target(window);

    mpd_connection = MPD.connection_new(null, 0, 0);
    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors("Initializing MPD connection");

    mpd_fd = MPD.connection_get_fd(mpd_connection);
    handle_errors("Getting file descriptor for MPD connection");

    assert(mpd_connection != null);
    MPD.send_list_queue_meta(mpd_connection);
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");
    if !entity { print("Failed retrieving MPD metadata\n"); exit(1); }

    queue: [..] Song;
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

        reset_temporary_storage();
    }

    columns: [4] [..] string;

    for song: queue {
        array_add(*columns[0], song.name);
        array_add(*columns[1], song.album);
        array_add(*columns[2], song.artist);
        array_add(*columns[3], "0:00");
    }

    SEEK_SECONDS         :: 0.5;
    VOLUME_CHANGE_AMOUNT :: 2;

    // TODO: would be nice to generalize this functionality, e.g. binding keys to functionality
    // then having the hold delay -> repeat functionality logic generated automatically (or
    // abstracted + looped)
    j_pressed_on_frame                   := 0;
    k_pressed_on_frame                   := 0;
    u_pressed_on_frame                   := 0;
    d_pressed_on_frame                   := 0;
    equals_pressed_on_frame              := 0;
    dash_pressed_on_frame                := 0;
    enter_pressed_on_frame               := 0;
    b_pressed_on_frame                   := 0;
    f_pressed_on_frame                   := 0;
    left_angle_bracket_pressed_on_frame  := 0;
    right_angle_bracket_pressed_on_frame := 0;

    last_key_pressed: Input.Key_Code;

    reset_temporary_storage();

    handle_mpd_idle_events :: () {
        assert(mpd_connection != null);
        if idle && MPD.send_noidle(mpd_connection) {
            idle = false;
    		flags := MPD.recv_idle(mpd_connection, true);
    		MPD.response_finish(mpd_connection);
    		handle_errors("Getting idle events");

            print("flags: %\n", flags);
        }
    }

    frame := 0;
    quit := false;
    while !quit {

        if !idle MPD.send_idle(mpd_connection);
        handle_errors("Putting MPD into idle mode");
        idle = true;

        new_cursor: Cursor;
        new_cursor.position = cursor.position;

        Input.update_window_events();
        for Input.events_this_frame {
            if it.type == {
              case .QUIT;
                quit = true;
                break;

              case .KEYBOARD;
                if it.key_pressed {
                    if it.key_code == {

                      case KEY_J;
                        j_pressed_on_frame = frame;
                        last_key_pressed = KEY_J;
                        new_cursor.position += 1;
                      case KEY_K;
                        k_pressed_on_frame = frame;
                        last_key_pressed = KEY_K;
                        new_cursor.position -= 1;

                      case KEY_D;
                        d_pressed_on_frame = frame;
                        last_key_pressed = KEY_D;
                        new_cursor.position += ITEMS_IN_PAGE;
                      case KEY_U;
                        u_pressed_on_frame = frame;
                        last_key_pressed = KEY_U;
                        new_cursor.position -= ITEMS_IN_PAGE;

                      case KEY_P;
                        handle_mpd_idle_events();
                        MPD.run_toggle_pause(mpd_connection);
                        handle_errors("");

                      case KEY_C;
                        handle_mpd_idle_events();
                        MPD.run_clear(mpd_connection);
                        handle_errors("");

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
                        handle_mpd_idle_events();
                        MPD.run_play_pos(mpd_connection, cast(u32)cursor.position);
                        handle_errors("");

                      case KEY_B;
                        b_pressed_on_frame = frame;
                        last_key_pressed = KEY_B;
                        handle_mpd_idle_events();
                        MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
                        handle_errors("");
                      case KEY_F;
                        f_pressed_on_frame = frame;
                        last_key_pressed = KEY_F;
                        handle_mpd_idle_events();
                        MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
                        handle_errors("");

                      case .LEFT_ANGLE_BRACKET;
                        left_angle_bracket_pressed_on_frame = frame;
                        last_key_pressed = .LEFT_ANGLE_BRACKET;
                        handle_mpd_idle_events();
                        MPD.run_previous(mpd_connection);
                        handle_errors("");
                      case .RIGHT_ANGLE_BRACKET;
                        right_angle_bracket_pressed_on_frame = frame;
                        last_key_pressed = .RIGHT_ANGLE_BRACKET;
                        handle_mpd_idle_events();
                        MPD.run_next(mpd_connection);
                        handle_errors("");

                      case .EQUALS_SIGN;
                        equals_pressed_on_frame = frame;
                        last_key_pressed = .EQUALS_SIGN;
                        handle_mpd_idle_events();
                        MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
                        handle_errors("");
                      case .DASH;
                        dash_pressed_on_frame = frame;
                        last_key_pressed = .DASH;
                        handle_mpd_idle_events();
                        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                        handle_errors("");

                      case KEY_Q;
                        quit = true;
                        break it;

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
           KEY_J == last_key_pressed                   &&
           frame > j_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.position += 1;
        } else
        if Input.input_button_states[KEY_K] & .DOWN    &&
           frame % 2                                   &&
           KEY_K == last_key_pressed                   &&
           frame > k_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.position -= 1;
        }

        if Input.input_button_states[KEY_D] & .DOWN    &&
           frame % 2                                   &&
           KEY_D == last_key_pressed                   &&
           frame > d_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.position += ITEMS_IN_PAGE;
        } else
        if Input.input_button_states[KEY_U] & .DOWN    &&
           frame % 2                                   &&
           KEY_U == last_key_pressed                   &&
           frame > u_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.position -= ITEMS_IN_PAGE;
        }

        if Input.input_button_states[Input.Key_Code.EQUALS_SIGN] & .DOWN &&
           frame % 2                                                     &&
           Input.Key_Code.EQUALS_SIGN == last_key_pressed                &&
           frame > equals_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
            handle_errors("");
        } else
        if Input.input_button_states[Input.Key_Code.DASH] & .DOWN &&
           frame % 2                                              &&
           Input.Key_Code.DASH == last_key_pressed                &&
           frame > dash_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
            handle_errors("");
        }

        if Input.input_button_states[Input.Key_Code.LEFT_ANGLE_BRACKET] & .DOWN &&
           frame % 2                                                            &&
           Input.Key_Code.LEFT_ANGLE_BRACKET == last_key_pressed                &&
           frame > left_angle_bracket_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_previous(mpd_connection);
            handle_errors("");
        } else
        if Input.input_button_states[Input.Key_Code.RIGHT_ANGLE_BRACKET] & .DOWN &&
           frame % 2                                                             &&
           Input.Key_Code.RIGHT_ANGLE_BRACKET == last_key_pressed                &&
           frame > right_angle_bracket_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_next(mpd_connection);
            handle_errors("");
        }

        if Input.input_button_states[KEY_B] & .DOWN &&
           frame % 2                                &&
           KEY_B == last_key_pressed                &&
           frame > b_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
            handle_errors("");
        } else
        if Input.input_button_states[KEY_F] & .DOWN &&
           frame % 2                                &&
           KEY_F == last_key_pressed                &&
           frame > f_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
            handle_errors("");
        }

        if Input.input_button_states[Input.Key_Code.ENTER] & .DOWN &&
           frame % 2                                               &&
           Input.Key_Code.ENTER == last_key_pressed                &&
           frame > enter_pressed_on_frame + 20
        {
            handle_mpd_idle_events();
            MPD.run_play_pos(mpd_connection, cast(u32)cursor.position);
            handle_errors("");
        }

        if new_cursor.position < 0                 new_cursor.position = 0;
        if new_cursor.position >= columns[0].count new_cursor.position = columns[0].count - 1;

        cursor = new_cursor;

        draw_one_frame(columns);
        // TODO: would be good to frame %= LARGE_NUMBER or something so this doesn't overflow,
        // but the *_pressed_on_frame values would need to be updated as well
        frame += 1;
        reset_temporary_storage();
    }

    print("Exiting\n");
    MPD.connection_free(mpd_connection);
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
window_width  : s32 : 1900;
window_height : s32 : 1440;
pixel_height := window_height / 48;
column_widths :: int.[700, 400, 400, 200];
ITEMS_IN_PAGE :: 30;

draw_queue_screen :: (columns: [4] [..] string) {
}
draw_library_screen :: (columns: [3] [..] string) {
}
draw_one_frame :: (columns: [4] [..] string) {

    Simp.clear_render_target(0,0,0,1);

    total_column_width := 0; for column_widths total_column_width += it;
    left_bound := cast(int) (window_width - total_column_width) / 2;
    original_y := cast(int) (window_height / 2 + ITEMS_IN_PAGE * (font.character_height + text_padding_y) / 2);
    text_padding_y :: 5;

    index_start := max(0, min(columns[0].count - ITEMS_IN_PAGE + 1, cursor.position - ITEMS_IN_PAGE/ 2 + 1));
    index_end := min(index_start + ITEMS_IN_PAGE, columns[0].count - 1);

    x := left_bound;
    {
        y := original_y;
        max_characters_in_column := (column_widths[0] - 100) / font.em_width;

        for i: index_start..index_end {
            song_name := columns[0][i];

            width := Simp.prepare_text(font, slice(song_name, 0, max_characters_in_column));
            if i == cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(1,1,1,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[0], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_widths[0];
    {
        y := original_y;
        max_characters_in_column := (column_widths[1] - 100) / font.em_width;

        for i: index_start..index_end {
            album := columns[1][i];

            width := Simp.prepare_text(font, slice(album, 0, max_characters_in_column));
            if i == cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[1], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_widths[1];
    {
        y := original_y;
        max_characters_in_column := (column_widths[2] - 100) / font.em_width;

        for i: index_start..index_end {
            artist := columns[2][i];

            width := Simp.prepare_text(font, slice(artist, 0, max_characters_in_column));
            if i == cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[2], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_widths[2];
    {
        y := original_y;
        max_characters_in_column := (column_widths[3] - 100) / font.em_width;

        for i: index_start..index_end {
            song_length := columns[3][i];
            display_song_length := left_pad(slice(song_length, 0, max_characters_in_column), #char " ", max_characters_in_column);
            width := Simp.prepare_text(font, slice(display_song_length, 0, max_characters_in_column));
            if i == cursor.position {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_widths[3], cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    Simp.swap_buffers(window);
    reset_temporary_storage();
}

// TODO: load/use font for asian/etc. characters (maybe one of the expanded inconsolata sets?)
font, font_bold : *Simp.Dynamic_Font;
init_fonts :: () {

    font = Simp.get_font_at_size(".", "Inconsolata-Regular.ttf", pixel_height);
    assert(font != null);

    font_bold = Simp.get_font_at_size(".", "Inconsolata-SemiBold.ttf", pixel_height);
    assert(font_bold != null);
}

Error :: struct {
    code: MPD.server_error;
    message: string;
    recovered: bool;
    type: enum { SERVER; CLIENT; };
}

Server_Error :: struct {
    using _error: Error;
    type = .SERVER;
}

Client_Error :: struct {
    using _error: Error;
    type = .CLIENT;
}

// TODO: add string arg to this to prefix error output with
// handle_errors :: (msg: string) {
//
// returns true if a reconnect happened, false otherwise
handle_errors :: (message: string) -> bool {
    error := check_connection_errors();
    if error {
        print("%: % error, code=%, message='%', recovered=%\n", message, error.type, error.code, error.message, error.recovered);
        if !error.recovered {
            print("Failed to recover from error, attempting to reconnect to MPD\n");

            MPD.run_clear(mpd_connection);
            mpd_connection = MPD.connection_new(null, 0, 0);
            if mpd_connection == null {
                print("MPD reconnect failed, might be out of memory. Exiting\n");
                exit(1);
            }

            // TODO: if we get 'connection refused', wait a second before restarting (goes wayy to fast for my laptop)
            new_connection_error := check_connection_errors();
            while new_connection_error {
                MPD.run_clear(mpd_connection);
                mpd_connection = MPD.connection_new(null, 0, 0);
                new_connection_error = check_connection_errors();
                print("Failed to reconnect: % error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
            }

            mpd_fd = MPD.connection_get_fd(mpd_connection);
            handle_errors("Getting file descriptor for MPD connection");

            print("Successfully reconnected to MPD\n");
            return true;
        }
        print("Recovered from error\n");
    }
    return false;
}

check_connection_errors :: () -> *Error {
	error_code := MPD.connection_get_error(mpd_connection);
	if (error_code != .SUCCESS) {
		msg := copy_from_c_string(MPD.connection_get_error_message(mpd_connection));

		if error_code == .SERVER {
    		error := New(Server_Error);
			error.code      = MPD.connection_get_server_error(mpd_connection);
			error.recovered = MPD.connection_clear_error(mpd_connection);
			return error;
		} else {
    		error := New(Client_Error);
    		error.message   = msg;
			error.recovered = MPD.connection_clear_error(mpd_connection);
			return error;
		}
	}

	return null;
}
