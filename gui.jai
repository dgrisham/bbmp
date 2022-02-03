#import "Basic";
#import "Math";
#import "Window_Creation";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

KEY_B :: 66;
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

// window_width  : s32 : 2560;
// window_height : s32 : 1440;

window_width  : s32 : 1920;
window_height : s32 : 1080;

window : Window_Type;

Artist  :: struct {
    name   : string;
    // albums : [] Album;
    // uri  : string;
}
free :: (artist: Artist) {
    free(artist.name);
}

Album :: struct {
    name : string;
    date : string;
    // songs : [] Song;
    // uri  : string;
};
free :: (album: Album) {
    free(album.name);
    free(album.date);
}

Song :: struct {
    name  : string;
    track : string;
    uri   : string;
}
free :: (song: Song) {
    free(song.name);
    free(song.track);
    free(song.uri);
}

Cursor :: struct {
    positions := int.[0, 0, 0];
    selected  := 0;
}

cursor: Cursor;

ITEMS_IN_PAGE :: 30;

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

    get_artists :: (connection: *MPD.connection) -> [] Artist {
        assert(connection != null);
        MPD.search_db_tags(connection, .ALBUM_ARTIST);
        MPD.search_commit(connection);
        handle_errors(connection);

        artists : [..] Artist;
        pair := MPD.recv_pair_tag(connection, .ALBUM_ARTIST);
        while pair {
            artist: Artist;
            artist.name = copy_string(to_string(pair.value));
            array_add(*artists, artist);

            MPD.return_pair(connection, pair);
            pair = MPD.recv_pair_tag(connection, .ALBUM_ARTIST);
        }
        handle_errors(connection);
        return artists;
    }
    artists := get_artists(mpd_connection);

    get_albums_for_artist :: (connection: *MPD.connection, artist: string) -> [] Album {
        albums: [..] Album;

        MPD.search_db_songs(connection, true);
        MPD.search_add_tag_constraint(connection, .MPD_OPERATOR_DEFAULT, .ALBUM_ARTIST, temp_c_string(artist));
        MPD.search_add_sort_tag(connection, .DATE, false);
        MPD.search_commit(connection);
        handle_errors(connection);

        mpd_song := MPD.recv_song(connection);
        while mpd_song {
            album_name := to_string(MPD.song_get_tag(mpd_song, .ALBUM, 0));
            found := false;
            for albums {
                if it.name == album_name { found = true; break; }
            }
            if !found {
                album: Album;
                album.name = copy_string(album_name);
                album.date = copy_string(to_string(MPD.song_get_tag(mpd_song, .DATE, 0)));
                array_add(*albums, album);
            }

            MPD.song_free(mpd_song);
            mpd_song = MPD.recv_song(connection);
        }

        return albums;
    }
    albums := get_albums_for_artist(mpd_connection, artists[0].name);

    get_songs_for_album :: (connection: *MPD.connection, artist: string, album: string) -> [] Song {
        songs: [..] Song;

        MPD.search_db_songs(connection, true);
        MPD.search_add_tag_constraint(connection, .MPD_OPERATOR_DEFAULT, .ALBUM_ARTIST, temp_c_string(artist));
        MPD.search_add_tag_constraint(connection, .MPD_OPERATOR_DEFAULT, .ALBUM,        temp_c_string(album));
        MPD.search_add_sort_tag(connection, .TRACK, false);
        MPD.search_commit(connection);
        handle_errors(connection);

        mpd_song := MPD.recv_song(connection);
        while mpd_song {
            song: Song;
            song.name  = copy_string(to_string(MPD.song_get_tag(mpd_song, .TITLE, 0)));
            song.track = copy_string(to_string(MPD.song_get_tag(mpd_song, .TRACK, 0)));
            song.uri   = copy_string(to_string(MPD.song_get_uri(mpd_song)));
            array_add(*songs, song);

            MPD.song_free(mpd_song);
            mpd_song = MPD.recv_song(connection);
        }

        return songs;
    }
    songs := get_songs_for_album(mpd_connection, artists[0].name, albums[0].name);

    columns: [3] [..] string;

    array_resize(*columns[0], artists.count);
    array_resize(*columns[1], albums.count);
    array_resize(*columns[2], songs.count);

    for artists columns[0][it_index] = it.name;
    for albums  columns[1][it_index] = sprint("(%) %", it.date, it.name);
    for songs {
        if it.track.count == 1 columns[2][it_index] = sprint(" % - %", it.track, it.name);;
        else                   columns[2][it_index] = sprint("% - %", it.track, it.name);;
    }

    SEEK_SECONDS         :: 0.5;
    VOLUME_CHANGE_AMOUNT :: 2;

    // TODO: would be nice to generalize this functionality, e.g. binding keys to functionality
    // then having the hold delay -> repeat functionality logic generated automatically (or
    // abstracted + looped)
    j_pressed_on_frame                   := 0;
    k_pressed_on_frame                   := 0;
    h_pressed_on_frame                   := 0;
    l_pressed_on_frame                   := 0;
    u_pressed_on_frame                   := 0;
    d_pressed_on_frame                   := 0;
    equals_pressed_on_frame              := 0;
    dash_pressed_on_frame                := 0;
    space_pressed_on_frame               := 0;
    enter_pressed_on_frame               := 0;
    b_pressed_on_frame                   := 0;
    f_pressed_on_frame                   := 0;
    left_angle_bracket_pressed_on_frame  := 0;
    right_angle_bracket_pressed_on_frame := 0;

    // TODO: these are slow. figure out how to map between directories and artists/albums
    add_album_to_queue :: (connection: *MPD.connection, artist_name: string, album_name: string) -> s32 {
        first_id_added: s32;
        for song: get_songs_for_album(connection, artist_name, album_name) {
            id := MPD.run_add_id(connection, temp_c_string(song.uri));
            if it_index == 0 {
                first_id_added = id;
            }
        }
        return first_id_added;
    }
    add_artist_to_queue :: (connection: *MPD.connection, artist_name: string) -> s32 {
        first_id_added: s32;
        for album, album_index: get_albums_for_artist(connection, artist_name) {
            id: s32;
            for song, song_index: get_songs_for_album(connection, artist_name, album.name) {
                id = MPD.run_add_id(connection, temp_c_string(song.uri));
                if album_index == 0 && song_index == 0 {
                    first_id_added = id;
                }
            }
        }
        return first_id_added;
    }

    reset_temporary_storage();

    frame := 0;
    quit := false;
    while !quit {

        new_cursor: Cursor;
        for cursor.positions new_cursor.positions[it_index] = it;
        new_cursor.selected = cursor.selected;

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
                        new_cursor.positions[new_cursor.selected] += 1;
                      case KEY_K;
                        k_pressed_on_frame = frame;
                        new_cursor.positions[new_cursor.selected] -= 1;

                      case KEY_L;
                        l_pressed_on_frame = frame;
                        new_cursor.selected += 1;
                      case KEY_H;
                        h_pressed_on_frame = frame;
                        new_cursor.selected -= 1;

                      case KEY_D;
                        d_pressed_on_frame = frame;
                        new_cursor.positions[new_cursor.selected] += ITEMS_IN_PAGE;
                      case KEY_U;
                        u_pressed_on_frame = frame;
                        new_cursor.positions[new_cursor.selected] -= ITEMS_IN_PAGE;

                      case KEY_P;
                        assert(mpd_connection != null);
                        MPD.run_toggle_pause(mpd_connection);
                        handle_errors(mpd_connection);

                      // case KEY_O;
                      //   for song: songs if song.uri == NOW_PLAYING_URI new_cursor.positions[new_cursor.selected] = it_index;

                      case .SPACEBAR;
                        space_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        if cursor.selected == {
                          case 0;
                            add_artist_to_queue(mpd_connection, artists[cursor.positions[0]].name);
                          case 1;
                            add_album_to_queue(mpd_connection, artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
                          case 2;
                            MPD.run_add_id(mpd_connection, temp_c_string(songs[new_cursor.positions[2]].uri));
                        }
                        new_cursor.positions[new_cursor.selected] += 1;

                      case .ENTER;
                        enter_pressed_on_frame = frame;
                        song_id_to_play: s32;

                        assert(mpd_connection != null);
                        if cursor.selected == {
                          case 0;
                            song_id_to_play = add_artist_to_queue(mpd_connection, artists[cursor.positions[0]].name);
                          case 1;
                            song_id_to_play = add_album_to_queue(mpd_connection, artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
                          case 2;
                            song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(songs[cursor.positions[2]].uri));
                        }
                        new_cursor.positions[new_cursor.selected] += 1;

                        if song_id_to_play >= 0 { // play first song that was added
                            assert(mpd_connection != null);
                            MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                            handle_errors(mpd_connection);
                        }

                      case KEY_B;
                        b_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
                        handle_errors(mpd_connection);
                      case KEY_F;
                        f_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
                        handle_errors(mpd_connection);

                      case .LEFT_ANGLE_BRACKET;
                        left_angle_bracket_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        MPD.run_previous(mpd_connection);
                        handle_errors(mpd_connection);
                      case .RIGHT_ANGLE_BRACKET;
                        right_angle_bracket_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        MPD.run_next(mpd_connection);
                        handle_errors(mpd_connection);

                      case .EQUALS_SIGN;
                        equals_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
                        handle_errors(mpd_connection);
                      case .DASH;
                        dash_pressed_on_frame = frame;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                        handle_errors(mpd_connection);

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
           j_pressed_on_frame > k_pressed_on_frame     &&
           frame > j_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] += 1;
        } else
        if Input.input_button_states[KEY_K] & .DOWN    &&
           frame % 2                                   &&
           k_pressed_on_frame > j_pressed_on_frame     &&
           frame > k_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] -= 1;
        }

        if Input.input_button_states[KEY_L] & .DOWN    &&
           frame % 2                                   &&
           l_pressed_on_frame > h_pressed_on_frame     &&
           frame > l_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.selected += 1;
        } else
        if Input.input_button_states[KEY_H] & .DOWN    &&
           frame % 2                                   &&
           h_pressed_on_frame > l_pressed_on_frame     &&
           frame > h_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.selected -= 1;
        }

        if Input.input_button_states[KEY_D] & .DOWN    &&
           frame % 2                                   &&
           d_pressed_on_frame > u_pressed_on_frame     &&
           frame > d_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] += ITEMS_IN_PAGE;
        } else
        if Input.input_button_states[KEY_U] & .DOWN    &&
           frame % 2                                   &&
           u_pressed_on_frame > d_pressed_on_frame     &&
           frame > u_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] -= ITEMS_IN_PAGE;
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

        if Input.input_button_states[Input.Key_Code.LEFT_ANGLE_BRACKET] & .DOWN       &&
           frame % 2                                                                  &&
           left_angle_bracket_pressed_on_frame > right_angle_bracket_pressed_on_frame &&
           frame > left_angle_bracket_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_previous(mpd_connection);
            handle_errors(mpd_connection);
        } else
        if Input.input_button_states[Input.Key_Code.RIGHT_ANGLE_BRACKET] & .DOWN      &&
           frame % 2                                                                  &&
           right_angle_bracket_pressed_on_frame > left_angle_bracket_pressed_on_frame &&
           frame > right_angle_bracket_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_next(mpd_connection);
            handle_errors(mpd_connection);
        }

        if Input.input_button_states[KEY_B] & .DOWN &&
           frame % 2                                &&
           b_pressed_on_frame > f_pressed_on_frame  &&
           frame > b_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
            handle_errors(mpd_connection);
        } else
        if Input.input_button_states[KEY_F] & .DOWN &&
           frame % 2                                &&
           f_pressed_on_frame > b_pressed_on_frame  &&
           frame > f_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
            handle_errors(mpd_connection);
        }

        if Input.input_button_states[Input.Key_Code.ENTER] & .DOWN &&
           frame % 2                                               &&
           frame > enter_pressed_on_frame + 20
        {
            song_id_to_play: s32;

            assert(mpd_connection != null);
            if cursor.selected == {
              case 0;
                song_id_to_play = add_artist_to_queue(mpd_connection, artists[cursor.positions[0]].name);
              case 1;
                song_id_to_play = add_album_to_queue(mpd_connection, artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
              case 2;
                song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(songs[cursor.positions[2]].uri));
            }
            new_cursor.positions[new_cursor.selected] += 1;

            if song_id_to_play >= 0 { // play first song that was added
                assert(mpd_connection != null);
                MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                handle_errors(mpd_connection);
            }
        }

        if Input.input_button_states[Input.Key_Code.SPACEBAR] & .DOWN &&
           frame % 2                                    &&
           frame > space_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            if cursor.selected == {
              case 0;
                add_artist_to_queue(mpd_connection, artists[cursor.positions[0]].name);
              case 1;
                add_album_to_queue(mpd_connection, artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
              case 2;
                MPD.run_add_id(mpd_connection, temp_c_string(songs[new_cursor.positions[2]].uri));
            }
            new_cursor.positions[new_cursor.selected] += 1;
            space_pressed_on_frame = frame;
        }

        // if Input.input_button_states[Input.Key_Code.SPACEBAR] & .DOWN &&
        //    frame % 2                                                  &&
        //    frame > space_pressed_on_frame + KEY_HOLD_DELAY
        // {
        //     assert(mpd_connection != null);
        //     id := MPD.run_add_id(mpd_connection, temp_c_string(songs[new_cursor.positions[new_cursor.selected]].uri));
        //     handle_errors(mpd_connection);
        //     new_cursor.positions[new_cursor.selected] += 1;
        // }

        if new_cursor.selected != cursor.selected {
            if new_cursor.selected < 0
                new_cursor.selected = 0;
            if new_cursor.selected >= new_cursor.positions.count
                new_cursor.selected = new_cursor.positions.count - 1;
        }

        for * new_cursor.positions {

            if (<<it) != cursor.positions[it_index] {
                if <<it < 0 {
                    <<it = 0;
                } else
                if <<it >= columns[it_index].count {
                    <<it = columns[it_index].count - 1;
                }

                if it_index == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
                if it_index == 1 new_cursor.positions[2] = 0;

                if it_index < 1 { // update albums
                    for albums free(it);
                    albums = get_albums_for_artist(mpd_connection, artists[new_cursor.positions[0]].name);

                    for columns[1] free(it);
                    array_resize(*columns[1], albums.count);
                    for albums {
                        columns[1][it_index] = sprint("(%) %", it.date, it.name);
                    }
                }

                if it_index < 2 { // update songs
                    for songs free(it);
                    songs = get_songs_for_album(mpd_connection, artists[new_cursor.positions[0]].name, albums[new_cursor.positions[1]].name);

                    for columns[2] free(it);
                    array_resize(*columns[2], songs.count);
                    for songs {
                        if it.track.count == 1 columns[2][it_index] = sprint(" % - %", it.track, it.name);;
                        else                   columns[2][it_index] = sprint("% - %", it.track, it.name);;
                    }
                }
            }
        }

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

draw_one_frame :: (columns: [3] [..] string) {

    Simp.clear_render_target(0,0,0,1);

    left_bound := 200;
    x_spacing := 700;
    original_y := window_height * 9 / 10 - font.character_height / 4;
    text_padding_y :: 5;

    {
        x := left_bound;
        y := original_y;

        index_start := max(0, cursor.positions[0] - ITEMS_IN_PAGE/ 2);
        i := index_start;
        while i <= index_start + ITEMS_IN_PAGE && i < columns[0].count  {
            artist := columns[0][i];

            width := Simp.prepare_text(font, artist);
            if i == cursor.positions[0] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx cursor.selected == 0 then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + 600, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
            i += 1;
        }
    }

    {
        x := left_bound + x_spacing;
        y := original_y;

        index_start := max(0, cursor.positions[1] - ITEMS_IN_PAGE/ 2);
        i := index_start;
        while i <= index_start + ITEMS_IN_PAGE && i < columns[1].count  {
            album := columns[1][i];

            width := Simp.prepare_text(font, album);
            if i == cursor.positions[1] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx cursor.selected == 1 then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + 600, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
            i += 1;
        }
    }

    {
        x := left_bound + 2 * x_spacing;
        y := original_y;

        index_start := max(0, cursor.positions[2] - ITEMS_IN_PAGE/ 2);
        i := index_start;
        while i <= index_start + ITEMS_IN_PAGE && i < columns[2].count  {
            song := columns[2][i];

            width := Simp.prepare_text(font, song);
            if i == cursor.positions[2] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx cursor.selected == 2 then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + 600, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
            i += 1;
        }
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
		msg := copy_string(to_string(MPD.connection_get_error_message(connection)));

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
