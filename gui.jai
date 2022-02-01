#import "Basic";
#import "Math";
#import "Window_Creation";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

// mpd_connection : *MPD.connection;

KEY_Q :: 81;

window_width  : s32 : 2560;
window_height : s32 : 1440;


window : Window_Type;

main :: () {

    init_font();

    window = create_window(window_width, window_height, "ncmpjai");
    Simp.set_render_target(window);

    mpd_connection := MPD.connection_new(null, 0, 0);

    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    error := check_connection_errors(mpd_connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
        print("Recovered\n");
    }

    // get test album
    // album_directory :: "vampire_weekend/2010_01-contra";
    // album_directory :: "danny_brown/2013_10-old";
    album_directory :: "lil_ugly_mane/2021_10-volcanic_bird_enemy_and_the_voiced_concern";
    // album_directory :: "the_angelic_process/2007_05-weighing_souls_with_sand";

    assert(mpd_connection != null);
    success := MPD.send_list_all_meta(mpd_connection, album_directory);
    if !success { print("Failure!\n"); exit(1); }

    error = check_connection_errors(mpd_connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
        print("Recovered\n");
    }

    artist : string;
    album  : string;
    songs  : [..] string;

    entity := MPD.recv_entity(mpd_connection);
    error = check_connection_errors(mpd_connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
        print("Recovered\n");
    }

    album_art_texture := New(Simp.Texture);
    assert(Simp.texture_load_from_file(album_art_texture, tprint("/home/grish/media/music/library/%/cover.jpg", album_directory)));
    reset_temporary_storage();

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            song  := MPD.entity_get_song(entity);
            title := to_string(MPD.song_get_tag(song, .TITLE, 0));
            if title {
                array_add(*songs, title);
                if songs.count == 1 {
                    artist = to_string(MPD.song_get_tag(song, .ALBUM_ARTIST, 0));
                    album  = to_string(MPD.song_get_tag(song, .ALBUM, 0));
                }
            }
        }
        entity = MPD.recv_entity(mpd_connection);
        error = check_connection_errors(mpd_connection);
        if error {
            print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
            if !error.recovered exit(1);
            print("Recovered\n");
        }

        reset_temporary_storage();
    }
    print("artist: %\n", artist);
    print("album: %\n", album);
    print("songs: %\n", songs);

    error = check_connection_errors(mpd_connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
        print("Recovered\n");
    }

    quit := false;
    while !quit {

        Input.update_window_events();
        for Input.events_this_frame {
            if it.type == {
              case .QUIT;
                quit = true;
                break;

              case .KEYBOARD;
                if it.key_pressed && it.key_code == KEY_Q {
                    quit = true;
                    break it;
                }
            }
        }

        draw_one_frame(album_art_texture, artist, album, songs);
    }

    print("Exiting\n");
    MPD.connection_free(mpd_connection);
}

draw_one_frame :: (album_art: *Simp.Texture, artist: string, album: string, songs: [] string) {

    Simp.clear_render_target(0,0,0,1);

    COVER_DISPLAY_WIDTH :: 500;
    cover_display_width  := cast(float)COVER_DISPLAY_WIDTH;
    cover_display_height := cast(float)COVER_DISPLAY_WIDTH * cast(float)album_art.height/album_art.width;

    COVER_X := cast(float)window_width  / 2 - cover_display_width - 100;
    COVER_Y :: cast(float)window_height / 2 - COVER_DISPLAY_WIDTH / 2;
    {
        Simp.set_shader_for_images(album_art);
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
        artist_name_width := Simp.prepare_text(font, artist);
        artist_name_x := text_center_x - artist_name_width / 2;
        Simp.draw_prepared_text(font, cast(s64)artist_name_x, y, rgba(1,1,1,1));
    }

    y -= text_padding_y + font.character_height;

    {
        album_name_width := Simp.prepare_text(font, album);
        album_name_x := text_center_x - album_name_width / 2;
        Simp.draw_prepared_text(font, album_name_x, y, rgba(1,1,1,1));
    }

    y = window_height * 2 / 3 - font.character_height / 4;

    for song: songs {
        width := Simp.prepare_text(font, tprint("% - %", it_index + 1, song));
        x := window_width / 2;
        Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
        y -= text_padding_y + font.character_height;
    }

    Simp.swap_buffers(window);
}

font: *Simp.Dynamic_Font;
init_font :: () {
    pixel_height := window_height / 64;
    font = Simp.get_font_at_size(".", "Inconsolata-Regular.ttf", pixel_height);
    assert(font != null);
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
