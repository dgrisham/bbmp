#import "Basic";
#import "Math";
#import "Window_Creation";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

// mpd_connection : *MPD.connection;

KEY_D :: 68;
KEY_J :: 74;
KEY_K :: 75;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_U :: 85;

NOW_PLAYING_URI: string;

// window_width  : s32 : 2560;
// window_height : s32 : 1440;

window_width  : s32 : 1920;
window_height : s32 : 1080;

window : Window_Type;

Artist  :: struct {
    name   : string;
    albums : [..] Album;
};

Album :: struct {
    name        : string;
    artist      : string;
    songs       : [..] Song;
    art_texture : *Simp.Texture;
};

Song :: struct {
    artist : string;
    album  : string;
    title  : string;
    track  : string;
    uri    : string;
}

main :: () {

    init_font();

    window = create_window(window_width, window_height, "ncmpjai");
    Simp.set_render_target(window);

    mpd_connection := MPD.connection_new(null, 0, 0);

    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors(mpd_connection);

    // get test album
    // album_directory :: "jpegmafia/2021_10-lp";
    // album_directory :: "youth_lagoon/2011_09-the_year_of_hibernation";
    // album_directory :: "vampire_weekend/2010_01-contra";
    // album_directory :: "casualties_of_cool/2014_05-casualties_of_cool";
    // album_directory :: "danny_brown/2013_10-old";
    // album_directory :: "lil_ugly_mane/2021_10-volcanic_bird_enemy_and_the_voiced_concern";
    // album_directory :: "the_angelic_process/2007_05-weighing_souls_with_sand";
    // album_directory :: "killswitch_engage/2006_01-as_daylight_dies";
    // album_directory :: "ac_dc/1977_03-let_there_be_rock";
    // album_directory :: "dinosaur_jr_/1987_07-youre_living_all_over_me";
    // album_directory :: "tipper/2014_05-forward_escape";
    album_directory :: "ariana_grande/2018_08-sweetener";

    assert(mpd_connection != null);
    success := MPD.send_list_all_meta(mpd_connection, album_directory);
    if !success { print("Failure!\n"); exit(1); }

    handle_errors(mpd_connection);

    entity := MPD.recv_entity(mpd_connection);
    handle_errors(mpd_connection);

    // TODO: we can probably get mpd stats and init the sizes of these tables accordingly
    // artists : Table(string, Artist);
    // albums  : Table(string, Album);

    album: Album;
    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);
            song: Song;
            song.title  = to_string(MPD.song_get_tag(mpd_song, .TITLE, 0));
            if song.title {
                song.artist = to_string(MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0));
                song.album  = to_string(MPD.song_get_tag(mpd_song, .ALBUM       , 0));
                song.track  = to_string(MPD.song_get_tag(mpd_song, .TRACK       , 0));
                song.uri    = to_string(MPD.song_get_uri(mpd_song));
                array_add(*album.songs, song);

                if !album.name && song.album {
                    album.name = song.album;
                }
                if !album.artist && song.artist {
                    album.artist = song.artist;
                }
            }
        } else {
            MPD.entity_free(entity);
        }
        entity = MPD.recv_entity(mpd_connection);
        handle_errors(mpd_connection);

        reset_temporary_storage();
    }

    handle_errors(mpd_connection);

    // exit(0);

    cover_filenames :: string.["cover.jpg", "cover.png"];
    album.art_texture = New(Simp.Texture);
    for cover_filenames {
        if Simp.texture_load_from_file(album.art_texture, tprint("/home/grish/media/music/library/%/%", album_directory, it)) break;
    }
    reset_temporary_storage();

    VOLUME_CHANGE_AMOUNT :: 1;

    j_down_on_frame      := 0;
    k_down_on_frame      := 0;
    u_down_on_frame      := 0;
    d_down_on_frame      := 0;
    equals_down_on_frame := 0;
    dash_down_on_frame   := 0;
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
                        j_down_on_frame = frame;
                      case KEY_K;
                        CURSOR_INDEX -= 1;
                        k_down_on_frame = frame;
                      case KEY_D;
                        CURSOR_INDEX += 5;
                        d_down_on_frame = frame;
                      case KEY_U;
                        CURSOR_INDEX -= 5;
                        u_down_on_frame = frame;

                      case KEY_O;
                        for song: album.songs if song.uri == NOW_PLAYING_URI CURSOR_INDEX = it_index;

                      case .SPACEBAR;
                        assert(mpd_connection != null);
                        id := MPD.run_add_id(mpd_connection, to_c_string(album.songs[CURSOR_INDEX].uri));
                        handle_errors(mpd_connection);
                        CURSOR_INDEX += 1;

                      case .LEFT_ANGLE_BRACKET;
                        assert(mpd_connection != null);
                        id := MPD.run_previous(mpd_connection);
                        handle_errors(mpd_connection);
                      case .RIGHT_ANGLE_BRACKET;
                        assert(mpd_connection != null);
                        id := MPD.run_next(mpd_connection);
                        handle_errors(mpd_connection);

                      case .ENTER;
                        uri := album.songs[CURSOR_INDEX].uri;
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
                        equals_down_on_frame = frame;
                      case .DASH;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                        handle_errors(mpd_connection);
                        dash_down_on_frame = frame;

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
        if Input.input_button_states[KEY_J] & .DOWN &&
           frame % 2                                &&
           j_down_on_frame > k_down_on_frame        &&
           frame > j_down_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX += 1;
        } else
        if Input.input_button_states[KEY_K] & .DOWN &&
           frame % 2                                &&
           k_down_on_frame > j_down_on_frame        &&
           frame > k_down_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX -= 1;
        }

        if Input.input_button_states[KEY_D] & .DOWN &&
           frame % 2                                &&
           d_down_on_frame > u_down_on_frame        &&
           frame > d_down_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX += 5;
        } else
        if Input.input_button_states[KEY_U] & .DOWN &&
           frame % 2                                &&
           u_down_on_frame > d_down_on_frame        &&
           frame > u_down_on_frame + KEY_HOLD_DELAY
        {
                CURSOR_INDEX -= 5;
        }

        if CURSOR_INDEX < 0 CURSOR_INDEX = 0;
        if CURSOR_INDEX >= album.songs.count CURSOR_INDEX = album.songs.count - 1;

        if Input.input_button_states[Input.Key_Code.EQUALS_SIGN] & .DOWN &&
           frame % 2                                      &&
           equals_down_on_frame > dash_down_on_frame      &&
           frame > equals_down_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
            handle_errors(mpd_connection);
        } else
        if Input.input_button_states[Input.Key_Code.DASH] & .DOWN   &&
           frame % 2                                 &&
           dash_down_on_frame > equals_down_on_frame &&
           frame > dash_down_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
            handle_errors(mpd_connection);
        }

        draw_one_frame(album);
        frame += 1;
    }

    print("Exiting\n");
    MPD.connection_free(mpd_connection);
}

CURSOR_INDEX := 0;

draw_one_frame :: (album: Album) {

    Simp.clear_render_target(0,0,0,1);

    COVER_DISPLAY_WIDTH :: 500;
    cover_display_width  := cast(float)COVER_DISPLAY_WIDTH;
    cover_display_height := cast(float)COVER_DISPLAY_WIDTH * cast(float)album.art_texture.height/album.art_texture.width;

    COVER_X := cast(float)window_width  / 2 - cover_display_width - 100;
    COVER_Y :: cast(float)window_height / 2 - COVER_DISPLAY_WIDTH / 2;
    {
        Simp.set_shader_for_images(album.art_texture);
        Simp.immediate_begin();

        v2 :: make_vector2;
        Simp.immediate_quad(
            xy(COVER_X                      , COVER_Y),
            xy(COVER_X + cover_display_width, COVER_Y),
            xy(COVER_X + cover_display_width, COVER_Y + cover_display_height),
            xy(COVER_X                      , COVER_Y + cover_display_height),
        );

        Simp.immediate_flush();
    }

    text_center_x  := (window_width - 100) / 2;
    y := cast(s64)(COVER_Y + cover_display_width + 100);
    text_padding_y :: 5;

    {
        artist_name_width := Simp.prepare_text(font, album.artist);
        artist_name_x := text_center_x - artist_name_width / 2;
        Simp.draw_prepared_text(font, cast(s64)artist_name_x, y, rgba(1,1,1,1));
    }

    y -= text_padding_y + font.character_height;

    {
        album_name_width := Simp.prepare_text(font, album.name);
        album_name_x := text_center_x - album_name_width / 2;
        Simp.draw_prepared_text(font, album_name_x, y, rgba(1,1,1,1));
    }

    y = window_height * 2 / 3 - font.character_height / 4;

    for song: album.songs {
        f := ifx song.uri == NOW_PLAYING_URI then font_bold else font;

        width := Simp.prepare_text(f, tprint("% - %", song.track, song.title));
        x := window_width / 2;
        if it_index == CURSOR_INDEX {
            Simp.immediate_begin();
            Simp.set_shader_for_color();
            Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + 500, cast(float)y + f.character_height, rgba(1,1,1,1));
            Simp.immediate_flush();
            Simp.draw_prepared_text(f, x, y, rgba(0,0,0,1));
        } else {
            Simp.draw_prepared_text(f, x, y, rgba(1,1,1,1));
        }
        y -= text_padding_y + font.character_height;
    }

    Simp.swap_buffers(window);
}

font, font_bold : *Simp.Dynamic_Font;
init_font :: () {
    pixel_height := window_height / 64;

    font = Simp.get_font_at_size(".", "Inconsolata-Regular.ttf", pixel_height);
    assert(font != null);

    font_bold = Simp.get_font_at_size(".", "Inconsolata-SemiBold.ttf", pixel_height);
    assert(font_bold != null);
}

// album_art_buffer: [..] u8;
// array_reserve(*album_art_buffer, 8192);
//
// BUFFER_MAX := 8192;
// buffer: *u8 = alloc(BUFFER_MAX);
// size := MPD.run_albumart(mpd_connection, "vampire_weekend/2007_04-vampire_weekend/cover.jpg", 0, cast(*void)buffer, cast(u64)BUFFER_MAX);
// memcpy(album_art_buffer.data, buffer.data, size);
// i: u32 = 1;
// while size != -1 {
//     size = MPD.run_albumart(mpd_connection, "vampire_weekend/2007_04-vampire_weekend/cover.jpg", 8192 * i, cast(*void)buffer, cast(u64)BUFFER_MAX);
//     print("i: %, size: %\n", i, size);
//     i += 1;
//     array_reserve(*album_art_buffer, album_art_buffer.count + 8192);
//     memcpy(album_art_buffer.data + album_art_buffer.count, buffer.data, size);
// }
// // we'll always get a failure on the last attempt to read the file
// MPD.connection_clear_error(mpd_connection);

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
