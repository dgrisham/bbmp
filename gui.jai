#import "Basic";
#import "Math";
#import "Window_Creation";

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

mpd_connection: *MPD.connection;

main :: () {

    init_fonts();

    window = create_window(window_width, window_height, "ncmpjai");
    Simp.set_render_target(window);

    mpd_connection = MPD.connection_new(null, 0, 0);
    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors();

    directory :: "";

    get_artists :: () -> [] Artist {
        assert(mpd_connection != null);
        MPD.search_db_tags(mpd_connection, .ALBUM_ARTIST);
        MPD.search_commit(mpd_connection);
        handle_errors();

        artists : [..] Artist;
        pair := MPD.recv_pair_tag(mpd_connection, .ALBUM_ARTIST);
        while pair {
            artist: Artist;
            artist.name = copy_string(to_string(pair.value));
            array_add(*artists, artist);

            MPD.return_pair(mpd_connection, pair);
            pair = MPD.recv_pair_tag(mpd_connection, .ALBUM_ARTIST);
        }
        handle_errors();
        return artists;
    }
    artists := get_artists();

    get_albums_for_artist :: (artist: string) -> [] Album {
        albums: [..] Album;

        MPD.search_db_songs(mpd_connection, true);
        MPD.search_add_tag_constraint(mpd_connection, .MPD_OPERATOR_DEFAULT, .ALBUM_ARTIST, temp_c_string(artist));
        MPD.search_add_sort_tag(mpd_connection, .DATE, false);
        MPD.search_commit(mpd_connection);
        handle_errors();

        mpd_song := MPD.recv_song(mpd_connection);
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
            mpd_song = MPD.recv_song(mpd_connection);
        }
        handle_errors();

        return albums;
    }
    albums := get_albums_for_artist(artists[0].name);

    get_songs_for_album :: (artist: string, album: string) -> [] Song {
        songs: [..] Song;

        MPD.search_db_songs(mpd_connection, true);
        MPD.search_add_tag_constraint(mpd_connection, .MPD_OPERATOR_DEFAULT, .ALBUM_ARTIST, temp_c_string(artist));
        MPD.search_add_tag_constraint(mpd_connection, .MPD_OPERATOR_DEFAULT, .ALBUM,        temp_c_string(album));
        MPD.search_add_sort_tag(mpd_connection, .TRACK, false);
        MPD.search_commit(mpd_connection);
        handle_errors();

        mpd_song := MPD.recv_song(mpd_connection);
        while mpd_song {
            song: Song;
            song.name  = copy_string(to_string(MPD.song_get_tag(mpd_song, .TITLE, 0)));
            song.track = copy_string(to_string(MPD.song_get_tag(mpd_song, .TRACK, 0)));
            song.uri   = copy_string(to_string(MPD.song_get_uri(mpd_song)));
            array_add(*songs, song);

            MPD.song_free(mpd_song);
            mpd_song = MPD.recv_song(mpd_connection);
        }
        handle_errors();

        return songs;
    }
    songs := get_songs_for_album(artists[0].name, albums[0].name);

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

    last_key_pressed: Input.Key_Code;

    // TODO: might be better to just add the entire directory if we can figure out an easy way to map between those and artists/albums
    add_album_to_queue :: (artist_name: string, album_name: string) -> s32 {
        first_id_added: s32;
        for song: get_songs_for_album(artist_name, album_name) {
            id := MPD.run_add_id(mpd_connection, temp_c_string(song.uri));
            if it_index == 0 {
                first_id_added = id;
            }
        }
        handle_errors();
        return first_id_added;
    }
    add_artist_to_queue :: (artist_name: string) -> s32 {
        first_id_added: s32;
        for album, album_index: get_albums_for_artist(artist_name) {
            id: s32;
            for song, song_index: get_songs_for_album(artist_name, album.name) {
                id = MPD.run_add_id(mpd_connection, temp_c_string(song.uri));
                if album_index == 0 && song_index == 0 {
                    first_id_added = id;
                }
            }
        }
        handle_errors();
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
                        last_key_pressed = KEY_J;
                        new_cursor.positions[new_cursor.selected] += 1;
                      case KEY_K;
                        k_pressed_on_frame = frame;
                        last_key_pressed = KEY_K;
                        new_cursor.positions[new_cursor.selected] -= 1;

                      case KEY_L;
                        l_pressed_on_frame = frame;
                        last_key_pressed = KEY_L;
                        new_cursor.selected += 1;
                      case KEY_H;
                        h_pressed_on_frame = frame;
                        last_key_pressed = KEY_H;
                        new_cursor.selected -= 1;

                      case KEY_D;
                        d_pressed_on_frame = frame;
                        last_key_pressed = KEY_D;
                        new_cursor.positions[new_cursor.selected] += ITEMS_IN_PAGE;
                      case KEY_U;
                        u_pressed_on_frame = frame;
                        last_key_pressed = KEY_U;
                        new_cursor.positions[new_cursor.selected] -= ITEMS_IN_PAGE;

                      case KEY_P;
                        assert(mpd_connection != null);
                        MPD.run_toggle_pause(mpd_connection);
                        handle_errors();

                      case KEY_C;
                        assert(mpd_connection != null);
                        MPD.run_clear(mpd_connection);
                        handle_errors();

                      // case KEY_O;
                      //   for song: songs if song.uri == NOW_PLAYING_URI new_cursor.positions[new_cursor.selected] = it_index;

                      case .SPACEBAR;
                        space_pressed_on_frame = frame;
                        last_key_pressed = .SPACEBAR;
                        assert(mpd_connection != null);
                        if cursor.selected == {
                          case 0;
                            add_artist_to_queue(artists[cursor.positions[0]].name);
                          case 1;
                            add_album_to_queue(artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
                          case 2;
                            MPD.run_add_id(mpd_connection, temp_c_string(songs[new_cursor.positions[2]].uri));
                        }
                        new_cursor.positions[new_cursor.selected] += 1;

                      case .ENTER;
                        enter_pressed_on_frame = frame;
                        last_key_pressed = .ENTER;
                        song_id_to_play: s32;

                        assert(mpd_connection != null);
                        if cursor.selected == {
                          case 0;
                            song_id_to_play = add_artist_to_queue(artists[cursor.positions[0]].name);
                          case 1;
                            song_id_to_play = add_album_to_queue(artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
                          case 2;
                            song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(songs[cursor.positions[2]].uri));
                        }
                        new_cursor.positions[new_cursor.selected] += 1;

                        if song_id_to_play >= 0 { // play first song that was added
                            assert(mpd_connection != null);
                            MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                            handle_errors();
                        }

                      case KEY_B;
                        b_pressed_on_frame = frame;
                        last_key_pressed = KEY_B;
                        assert(mpd_connection != null);
                        MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
                        handle_errors();
                      case KEY_F;
                        f_pressed_on_frame = frame;
                        last_key_pressed = KEY_F;
                        assert(mpd_connection != null);
                        MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
                        handle_errors();

                      case .LEFT_ANGLE_BRACKET;
                        left_angle_bracket_pressed_on_frame = frame;
                        last_key_pressed = .LEFT_ANGLE_BRACKET;
                        assert(mpd_connection != null);
                        MPD.run_previous(mpd_connection);
                        handle_errors();
                      case .RIGHT_ANGLE_BRACKET;
                        right_angle_bracket_pressed_on_frame = frame;
                        last_key_pressed = .RIGHT_ANGLE_BRACKET;
                        assert(mpd_connection != null);
                        MPD.run_next(mpd_connection);
                        handle_errors();

                      case .EQUALS_SIGN;
                        equals_pressed_on_frame = frame;
                        last_key_pressed = .EQUALS_SIGN;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
                        handle_errors();
                      case .DASH;
                        dash_pressed_on_frame = frame;
                        last_key_pressed = .DASH;
                        assert(mpd_connection != null);
                        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                        handle_errors();

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
            new_cursor.positions[new_cursor.selected] += 1;
        } else
        if Input.input_button_states[KEY_K] & .DOWN    &&
           frame % 2                                   &&
           KEY_K == last_key_pressed                   &&
           frame > k_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] -= 1;
        }

        if Input.input_button_states[KEY_L] & .DOWN    &&
           frame % 2                                   &&
           KEY_L == last_key_pressed                   &&
           frame > l_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.selected += 1;
        } else
        if Input.input_button_states[KEY_H] & .DOWN    &&
           frame % 2                                   &&
           KEY_H == last_key_pressed                   &&
           frame > h_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.selected -= 1;
        }

        if Input.input_button_states[KEY_D] & .DOWN    &&
           frame % 2                                   &&
           KEY_D == last_key_pressed                   &&
           frame > d_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] += ITEMS_IN_PAGE;
        } else
        if Input.input_button_states[KEY_U] & .DOWN    &&
           frame % 2                                   &&
           KEY_U == last_key_pressed                   &&
           frame > u_pressed_on_frame + KEY_HOLD_DELAY
        {
            new_cursor.positions[new_cursor.selected] -= ITEMS_IN_PAGE;
        }

        if Input.input_button_states[Input.Key_Code.EQUALS_SIGN] & .DOWN &&
           frame % 2                                                     &&
           Input.Key_Code.EQUALS_SIGN == last_key_pressed                &&
           frame > equals_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
            handle_errors();
        } else
        if Input.input_button_states[Input.Key_Code.DASH] & .DOWN &&
           frame % 2                                              &&
           Input.Key_Code.DASH == last_key_pressed                &&
           frame > dash_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
            handle_errors();
        }

        if Input.input_button_states[Input.Key_Code.LEFT_ANGLE_BRACKET] & .DOWN &&
           frame % 2                                                            &&
           Input.Key_Code.LEFT_ANGLE_BRACKET == last_key_pressed                &&
           frame > left_angle_bracket_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_previous(mpd_connection);
            handle_errors();
        } else
        if Input.input_button_states[Input.Key_Code.RIGHT_ANGLE_BRACKET] & .DOWN &&
           frame % 2                                                             &&
           Input.Key_Code.RIGHT_ANGLE_BRACKET == last_key_pressed                &&
           frame > right_angle_bracket_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_next(mpd_connection);
            handle_errors();
        }

        if Input.input_button_states[KEY_B] & .DOWN &&
           frame % 2                                &&
           KEY_B == last_key_pressed                &&
           frame > b_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
            handle_errors();
        } else
        if Input.input_button_states[KEY_F] & .DOWN &&
           frame % 2                                &&
           KEY_F == last_key_pressed                &&
           frame > f_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
            handle_errors();
        }

        if Input.input_button_states[Input.Key_Code.ENTER] & .DOWN &&
           frame % 2                                               &&
           Input.Key_Code.ENTER == last_key_pressed                &&
           frame > enter_pressed_on_frame + 20
        {
            song_id_to_play: s32;

            assert(mpd_connection != null);
            if cursor.selected == {
              case 0;
                song_id_to_play = add_artist_to_queue(artists[cursor.positions[0]].name);
              case 1;
                song_id_to_play = add_album_to_queue(artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
              case 2;
                song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(songs[cursor.positions[2]].uri));
            }
            new_cursor.positions[new_cursor.selected] += 1;

            if song_id_to_play >= 0 { // play first song that was added
                assert(mpd_connection != null);
                MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                handle_errors();
            }
        }

        if Input.input_button_states[Input.Key_Code.SPACEBAR] & .DOWN &&
           frame % 2                                                  &&
           Input.Key_Code.SPACEBAR == last_key_pressed                &&
           frame > space_pressed_on_frame + 20
        {
            assert(mpd_connection != null);
            if cursor.selected == {
              case 0;
                add_artist_to_queue(artists[cursor.positions[0]].name);
              case 1;
                add_album_to_queue(artists[cursor.positions[0]].name, albums[cursor.positions[1]].name);
              case 2;
                MPD.run_add_id(mpd_connection, temp_c_string(songs[new_cursor.positions[2]].uri));
            }
            new_cursor.positions[new_cursor.selected] += 1;
        }

        if new_cursor.selected != cursor.selected {
            if new_cursor.selected < 0
                new_cursor.selected = 0;
            if new_cursor.selected >= new_cursor.positions.count
                new_cursor.selected = new_cursor.positions.count - 1;
        }

        for * new_cursor.positions {

            if (<<it) != cursor.positions[it_index] { // cursor changed
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
                    albums = get_albums_for_artist(artists[new_cursor.positions[0]].name);

                    for columns[1] free(it);
                    array_resize(*columns[1], albums.count);
                    for albums {
                        columns[1][it_index] = sprint("(%) %", it.date, it.name);
                    }
                }

                if it_index < 2 { // update songs
                    for songs free(it);
                    songs = get_songs_for_album(artists[new_cursor.positions[0]].name, albums[new_cursor.positions[1]].name);

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

// window_width  : s32 : 2560;
// window_height : s32 : 1440;
// pixel_height := window_height / 96;
// column_width :: 700;
// ITEMS_IN_PAGE :: 50;

window_width  : s32 : 1920;
window_height : s32 : 1080;
pixel_height := window_height / 64;
column_width := 600;
ITEMS_IN_PAGE := 30;

draw_one_frame :: (columns: [3] [..] string) {

    Simp.clear_render_target(0,0,0,1);

    left_bound := cast(int) (window_width - column_width * 3) / 2;
    original_y := cast(int) (window_height / 2 + ITEMS_IN_PAGE * (font.character_height + text_padding_y) / 2);
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
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width - 100, cast(float)y + font.character_height, color);
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
        x := left_bound + column_width;
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
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width - 100, cast(float)y + font.character_height, color);
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
        x := left_bound + 2 * column_width;
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
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width - 100, cast(float)y + font.character_height, color);
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
handle_errors :: () {
    error := check_connection_errors();
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered {
            print("Failed to recover from error, attempting to reconnect to MPD\n");

            MPD.run_clear(mpd_connection);
            mpd_connection = MPD.connection_new(null, 0, 0);
            if mpd_connection == null {
                print("MPD reconnect failed, might be out of memory. Exiting\n");
                exit(1);
            }

            new_connection_error := check_connection_errors();
            while new_connection_error {
                MPD.run_clear(mpd_connection);
                mpd_connection = MPD.connection_new(null, 0, 0);
                new_connection_error = check_connection_errors();
                print("Failed to reconnect: % error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
            }

            print("Successfully reconnected to MPD\n");
        }
        print("Recovered from error\n");
    }
}

check_connection_errors :: () -> *Error {
	error_code := MPD.connection_get_error(mpd_connection);
	if (error_code != .SUCCESS) {
		msg := copy_string(to_string(MPD.connection_get_error_message(mpd_connection)));

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
