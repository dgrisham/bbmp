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

window : Window_Type;

library : struct {
    artists             : Table(string, Artist);
    sorted_artist_names : [..] string;
}

Artist  :: struct {
    name                       : string;
    albums                     : Table(string, Album);
    album_names_sorted_by_date : [..] string;
}

Album :: struct {
    name  : string;
    date  : string;
    songs : [..] Song;
};

Song :: struct {
    artist : string;
    album  : string;
    name   : string;
    track  : string;
    uri    : string;
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

    assert(mpd_connection != null);
    MPD.send_list_all_meta(mpd_connection, "");
    handle_errors();

    entity := MPD.recv_entity(mpd_connection);
    handle_errors();

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);

            mpd_artist := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
            mpd_album  := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
            mpd_title  := MPD.song_get_tag(mpd_song, .TITLE       , 0);
            mpd_date   := MPD.song_get_tag(mpd_song, .DATE        , 0);
            if mpd_artist && mpd_album && mpd_title {
                song: Song;
                song.artist = copy_string(to_string(mpd_artist));
                song.album  = copy_string(to_string(mpd_album));
                song.name   = copy_string(to_string(mpd_title));

                artist_ptr := table_find_pointer(library.artists, song.artist);
                if !artist_ptr {
                    artist: Artist;
                    artist.name = song.artist;
                    artist_ptr = table_add(*library.artists, song.artist, artist);
                    array_add(*library.sorted_artist_names, song.artist);
                }

                album_ptr := table_find_pointer(artist_ptr.albums, song.album);
                if !album_ptr {
                    album: Album;
                    album.name = song.album;
                    album.date = copy_string(to_string(mpd_date));
                    album_ptr = table_add(*artist_ptr.albums, song.album, album);
                    array_add(*artist_ptr.album_names_sorted_by_date, song.album); // TODO: sort these!
                }

                song.track  = to_string(MPD.song_get_tag(mpd_song, .TRACK, 0));
                song.uri    = to_string(MPD.song_get_uri(mpd_song));
                array_add(*album_ptr.songs, song);
            }
        } else {
            MPD.entity_free(entity);
        }
        entity = MPD.recv_entity(mpd_connection);
        handle_errors();

        reset_temporary_storage();
    }

    columns: [3] [..] string;

    array_resize(*columns[0], library.sorted_artist_names.count);
    for library.sorted_artist_names columns[0][it_index] = it;

    first_artist := table_find_pointer(library.artists, library.sorted_artist_names[0]);
    array_resize(*columns[1], first_artist.album_names_sorted_by_date.count);
    i := 0;
    for album_name: first_artist.album_names_sorted_by_date {
        album := table_find_pointer(first_artist.albums, album_name);
        columns[1][it_index] = sprint("(%) %", album.date, album.name);
        if it_index == 0 {
            array_resize(*columns[2], album.songs.count);
            for album.songs {
                if it.track.count == 1 columns[2][it_index] = sprint(" % - %", it.track, it.name);;
                else                   columns[2][it_index] = sprint("% - %", it.track, it.name);;
            }
        }
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
        artist := table_find_pointer(library.artists, artist_name);
        if !artist return -1;
        album := table_find_pointer(artist.albums, album_name);
        if !artist return -1;

        for song, song_index: album.songs {
            id := MPD.run_add_id(mpd_connection, temp_c_string(song.uri));
            if song_index == 0 {
                first_id_added = id;
            }
        }
        handle_errors();
        return first_id_added;
    }

    add_artist_to_queue :: (artist_name: string) -> s32 {
        first_id_added: s32;
        artist := table_find_pointer(library.artists, artist_name);
        if !artist return -1;
        for album_name, album_index: artist.album_names_sorted_by_date {
            album := table_find_pointer(artist.albums, album_name);

            for song, song_index: album.songs {
                id := MPD.run_add_id(mpd_connection, temp_c_string(song.uri));
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
                            add_artist_to_queue(library.sorted_artist_names[cursor.positions[0]]);
                          case 1;
                            artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                            add_album_to_queue(artist.name, artist.album_names_sorted_by_date[cursor.positions[1]]);
                          case 2;
                            artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                            album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[cursor.positions[1]]);
                            MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
                        }
                        new_cursor.positions[new_cursor.selected] += 1;

                      case .ENTER;
                        enter_pressed_on_frame = frame;
                        last_key_pressed = .ENTER;
                        song_id_to_play: s32;

                        assert(mpd_connection != null);
                        if cursor.selected == {
                          case 0;
                            song_id_to_play = add_artist_to_queue(library.sorted_artist_names[cursor.positions[0]]);
                          case 1;
                            artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                            song_id_to_play = add_album_to_queue(artist.name, artist.album_names_sorted_by_date[cursor.positions[1]]);
                          case 2;
                            artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                            album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[cursor.positions[1]]);
                            song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
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
                song_id_to_play = add_artist_to_queue(library.sorted_artist_names[cursor.positions[0]]);
              case 1;
                artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                song_id_to_play = add_album_to_queue(artist.name, artist.album_names_sorted_by_date[cursor.positions[1]]);
              case 2;
                artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[cursor.positions[1]]);
                song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
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
                add_artist_to_queue(library.sorted_artist_names[cursor.positions[0]]);
              case 1;
                artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                add_album_to_queue(artist.name, artist.album_names_sorted_by_date[cursor.positions[1]]);
              case 2;
                artist := table_find_pointer(library.artists, library.sorted_artist_names[cursor.positions[0]]);
                album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[cursor.positions[1]]);
                MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
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
                    artist_name := library.sorted_artist_names[new_cursor.positions[0]];
                    artist := table_find_pointer(library.artists, artist_name);
                    if !artist { print("Artist '%' not found\n", artist_name); exit(1); }

                    for columns[1] free(it);
                    array_resize(*columns[1], artist.album_names_sorted_by_date.count);
                    for album_name: artist.album_names_sorted_by_date {
                        album := table_find_pointer(artist.albums, album_name);
                        // if !album { print("Album '%' not found for artist '%'\n", album_name, artist_name); exit(1); }
                        columns[1][it_index] = sprint("(%) %", album.date, album.name);
                    }
                }

                if it_index < 2 { // update songs
                    artist_name := library.sorted_artist_names[new_cursor.positions[0]];
                    artist := table_find_pointer(library.artists, artist_name);
                    if !artist { print("Artist '%' not found\n", artist_name); exit(1); }
                    album_name := artist.album_names_sorted_by_date[new_cursor.positions[1]];
                    album := table_find_pointer(artist.albums, album_name);
                    if !album { print("Album '%' not found for artist '%'\n", album_name, artist_name); exit(1); }

                    for columns[2] free(it);
                    array_resize(*columns[2], album.songs.count);
                    for album.songs {
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

    max_characters_in_column := (column_width - 100) / font.em_width;

    {
        x := left_bound;
        y := original_y;

        index_start := max(0, cursor.positions[0] - ITEMS_IN_PAGE/ 2);
        i := index_start;
        while i <= index_start + ITEMS_IN_PAGE && i < columns[0].count  {
            artist := columns[0][i];

            width := Simp.prepare_text(font, slice(artist, 0, max_characters_in_column));
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

            width := Simp.prepare_text(font, slice(album, 0, max_characters_in_column));
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

            width := Simp.prepare_text(font, slice(song, 0, max_characters_in_column));
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
//
// returns true if a reconnect happened, false otherwise
handle_errors :: () -> bool {
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

            // TODO: if we get 'connection refused', wait a second before restarting (goes wayy to fast for my laptop)
            new_connection_error := check_connection_errors();
            while new_connection_error {
                MPD.run_clear(mpd_connection);
                mpd_connection = MPD.connection_new(null, 0, 0);
                new_connection_error = check_connection_errors();
                print("Failed to reconnect: % error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
            }

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
