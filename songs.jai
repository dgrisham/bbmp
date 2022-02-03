#import "Basic";
#import "Math";
#import "Window_Creation";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

KEY_D :: 68;
KEY_J :: 74;
KEY_K :: 75;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_U :: 85;

// TODO: get NOW_PLAYING_URI on start from mpd (+ maybe always use mpd to set it)
NOW_PLAYING_URI: string;

// window_width  : s32 : 2560;
// window_height : s32 : 1440;

window_width  : s32 : 1920;
window_height : s32 : 1080;

window : Window_Type;

// Artist  :: struct {
//     name   : string;
//     albums : [..] Album;
// };

// Album :: struct {
//     name        : string;
//     artist      : string;
//     songs       : [..] Song;
//     art_texture : *Simp.Texture;
// };

Song :: struct {
    artist : string;
    album  : string;
    title  : string;
    track  : string;
    uri    : string;
}

SONGS_IN_PAGE :: 30;

main :: () {

    init_fonts();

    window = create_window(window_width, window_height, "ncmpjai");
    Simp.set_render_target(window);

    mpd_connection := MPD.connection_new(null, 0, 0);

    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors(mpd_connection);

    // album_directory :: "ariana_grande/2018_08-sweetener";
    directory :: "";

    assert(mpd_connection != null);
    MPD.send_list_all_meta(mpd_connection, "");
    handle_errors(mpd_connection);

    entity := MPD.recv_entity(mpd_connection);
    handle_errors(mpd_connection);

    // TODO: we can probably get mpd stats and init the sizes of these tables accordingly
    // artists : Table(string, Artist);
    // albums  : Table(string, Album);

    songs: [..] Song;
    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song := MPD.entity_get_song(entity);
            song: Song;
            song.title  = to_string(MPD.song_get_tag(mpd_song, .TITLE, 0));
            if song.title {
                song.artist = to_string(MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0));
                song.album  = to_string(MPD.song_get_tag(mpd_song, .ALBUM       , 0));
                song.track  = to_string(MPD.song_get_tag(mpd_song, .TRACK       , 0));
                song.uri    = to_string(MPD.song_get_uri(mpd_song));
                array_add(*songs, song);
            }
        } else {
            MPD.entity_free(entity);
        }

        entity = MPD.recv_entity(mpd_connection);
        handle_errors(mpd_connection);

        reset_temporary_storage();
    }

    VOLUME_CHANGE_AMOUNT :: 1;

    // TODO: would be nice to generalize this functionality, e.g. binding keys to functionality
    // then having the hold delay -> repeat functionality logic generated automatically (or
    // abstracted + looped)
    j_pressed_on_frame      := 0;
    k_pressed_on_frame      := 0;
    u_pressed_on_frame      := 0;
    d_pressed_on_frame      := 0;
    equals_pressed_on_frame := 0;
    dash_pressed_on_frame   := 0;
    space_pressed_on_frame  := 0;

    frame := 0;
    quit := false;
    while !quit {

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
                        CURSOR_INDEX += 1;
                        j_pressed_on_frame = frame;
                      case KEY_K;
                        CURSOR_INDEX -= 1;
                        k_pressed_on_frame = frame;
                      case KEY_D;
                        CURSOR_INDEX += SONGS_IN_PAGE;
                        d_pressed_on_frame = frame;
                      case KEY_U;
                        CURSOR_INDEX -= SONGS_IN_PAGE;
                        u_pressed_on_frame = frame;

                      case KEY_O;
                        for song: songs if song.uri == NOW_PLAYING_URI CURSOR_INDEX = it_index;

                      case .SPACEBAR;
                        assert(mpd_connection != null);
                        id := MPD.run_add_id(mpd_connection, to_c_string(songs[CURSOR_INDEX].uri));
                        handle_errors(mpd_connection);
                        CURSOR_INDEX += 1;
                        space_pressed_on_frame = frame;

                      case .LEFT_ANGLE_BRACKET;
                        assert(mpd_connection != null);
                        id := MPD.run_previous(mpd_connection);
                        handle_errors(mpd_connection);
                      case .RIGHT_ANGLE_BRACKET;
                        assert(mpd_connection != null);
                        id := MPD.run_next(mpd_connection);
                        handle_errors(mpd_connection);

                      case .ENTER;
                        uri := songs[CURSOR_INDEX].uri;
                        assert(mpd_connection != null);
                        id := MPD.run_add_id(mpd_connection, to_c_string(uri));
                        handle_errors(mpd_connection);
                        if id >= 0 {
                            assert(mpd_connection != null);
                            MPD.run_play_id(mpd_connection, cast(u32)id);
                            handle_errors(mpd_connection);
                            NOW_PLAYING_URI = uri;
                        }

                      case .EQUALS_SIGN;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
                        handle_errors(mpd_connection);
                        equals_pressed_on_frame = frame;
                      case .DASH;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                        handle_errors(mpd_connection);
                        dash_pressed_on_frame = frame;

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
        // this emulates how curses/terminal application cursor movement tends to behave

        KEY_HOLD_DELAY :: 20;

        if Input.input_button_states[KEY_J] & .DOWN    &&
           frame % 2                                   &&
           j_pressed_on_frame > k_pressed_on_frame     &&
           frame > j_pressed_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX += 1;
        } else
        if Input.input_button_states[KEY_K] & .DOWN    &&
           frame % 2                                   &&
           k_pressed_on_frame > j_pressed_on_frame     &&
           frame > k_pressed_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX -= 1;
        }

        if Input.input_button_states[KEY_D] & .DOWN    &&
           frame % 2                                   &&
           d_pressed_on_frame > u_pressed_on_frame     &&
           frame > d_pressed_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX += SONGS_IN_PAGE;
        } else
        if Input.input_button_states[KEY_U] & .DOWN    &&
           frame % 2                                   &&
           u_pressed_on_frame > d_pressed_on_frame     &&
           frame > u_pressed_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX -= SONGS_IN_PAGE;
        }

        if Input.input_button_states[Input.Key_Code.EQUALS_SIGN] & .DOWN &&
           frame % 2                                                     &&
           equals_pressed_on_frame > dash_pressed_on_frame               &&
           frame > equals_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
            handle_errors(mpd_connection);
        } else
        if Input.input_button_states[Input.Key_Code.DASH] & .DOWN &&
           frame % 2                                              &&
           dash_pressed_on_frame > equals_pressed_on_frame        &&
           frame > dash_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
            handle_errors(mpd_connection);
        }

        if Input.input_button_states[Input.Key_Code.SPACEBAR] & .DOWN &&
           frame % 2                                                  &&
           frame > space_pressed_on_frame + KEY_HOLD_DELAY
        {
            assert(mpd_connection != null);
            id := MPD.run_add_id(mpd_connection, to_c_string(songs[CURSOR_INDEX].uri));
            handle_errors(mpd_connection);
            CURSOR_INDEX += 1;
        }

        if CURSOR_INDEX < 0 CURSOR_INDEX = 0;
        if CURSOR_INDEX >= songs.count CURSOR_INDEX = songs.count - 1;

        draw_one_frame(songs);
        frame += 1;
        // TODO: would be good to frame %= LARGE_NUMBER or something so this doesn't overflow,
        // but the *_pressed_on_frame values would need to be updated as well
    }

    print("Exiting\n");
    MPD.connection_free(mpd_connection);
}

CURSOR_INDEX := 0;

draw_one_frame :: (songs: [] Song) {

    Simp.clear_render_target(0,0,0,1);

    text_center_x  := (window_width - 100) / 2;
    text_padding_y :: 5;

    y := window_height * 4 / 5 - font.character_height / 4;

    song_index_start := max(0, CURSOR_INDEX - SONGS_IN_PAGE/ 2);
    i := song_index_start;
    while i <= song_index_start + SONGS_IN_PAGE && i < songs.count  {
        song := songs[i];
        f := ifx song.uri == NOW_PLAYING_URI then font_bold else font;

        // TODO: align e.g. " 1" and "13" (string builder? custom formatInt? see modules/Basic/Print.jai)
        // also see context.print_style usage in how_to/018_print_functions.jai
        width := Simp.prepare_text(f, tprint("% - %", song.track, song.title));
        x := window_width / 2;
        if i == CURSOR_INDEX {
            Simp.immediate_begin();
            Simp.set_shader_for_color();
            Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + 600, cast(float)y + f.character_height, rgba(1,1,1,1));
            Simp.immediate_flush();
            Simp.draw_prepared_text(f, x, y, rgba(0,0,0,1));
        } else {
            Simp.draw_prepared_text(f, x, y, rgba(1,1,1,1));
        }

        y -= text_padding_y + font.character_height;
        i += 1;
    }

    Simp.swap_buffers(window);
    reset_temporary_storage();
}

// TODO: load/use font for asian/etc. characters (maybe one of the expanded inconsolata sets?)
font, font_bold : *Simp.Dynamic_Font;
init_fonts :: () {
    pixel_height := window_height / 64;

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

handle_errors :: inline (connection: *MPD.connection) {
    error := check_connection_errors(connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
        print("Recovered from error\n");
    }
}

check_connection_errors :: (connection: *MPD.connection) -> *Error {
	error_code := MPD.connection_get_error(connection);
	if (error_code != .SUCCESS) {
		msg := to_string(MPD.connection_get_error_message(connection));

		if error_code == .SERVER {
    		error := New(Server_Error);
			error.code      = MPD.connection_get_server_error(connection);
			error.recovered = MPD.connection_clear_error(connection);
			return error;
		} else {
    		error := New(Client_Error);
    		error.message   = msg;
			error.recovered = MPD.connection_clear_error(connection);
			return error;
		}
	}

	return null;
}
