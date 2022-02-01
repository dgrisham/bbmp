#import "Basic";
#import "Window_Creation";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

// mpd_connection : *MPD.connection;

window_width  : s32 : 1920;
window_height : s32 : 1080;

window : Window_Type;

main :: () {

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
    assert(mpd_connection != null);
    album_directory :: "vampire_weekend/2010_01-contra";
    // id := MPD.run_update(mpd_connection, to_c_string("/home/grish/media/music/library"));
	// MPD.send_update(mpd_connection, "/home/grish/media/music/library");
	// MPD.recv_update_id(mpd_connection);
	// MPD.response_finish(mpd_connection);
 //    print("HERE 1\n");

    error = check_connection_errors(mpd_connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
        print("Recovered\n");
    }

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
    print("HERE 1\n");
    assert(Simp.texture_load_from_file(album_art_texture, "/home/grish/media/music/library/vampire_weekend/2010_01-contra/cover.jpg"));
    print("HERE 2\n");
    reset_temporary_storage();

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            print("HERE A\n");
            print("HERE B\n");
            title := MPD.song_get_tag(cast(*MPD.song)entity, .NAME, 0);
            if title {
                print("HERE C: %\n", title);
                song_title := to_string(title);
                print("HERE D: %\n", song_title);
                array_add(*songs, song_title);
                print("HERE E\n");
                if songs.count == 1 {
                    artist = to_string(MPD.song_get_tag(cast(*MPD.song)entity, .ALBUM_ARTIST, 0));
                    album  = to_string(MPD.song_get_tag(cast(*MPD.song)entity, .TITLE, 0));
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
        draw_one_frame(album_art_texture, artist, album, songs);
    }

    print("Exiting\n");
}

draw_one_frame :: (album_art: *Simp.Texture, artist: string, album: string, songs: [] string) {
    Simp.clear_render_target(1,1,1,1);
    Simp.immediate_begin();

    Simp.immediate_flush();
    Simp.swap_buffers(window);
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
