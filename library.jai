#import "Hash_Table";

library: struct {
    artists             : Table(string, Artist);
    artist_names_sorted : [..] string;
}

Artist  :: struct {
    name                       : string;
    albums                     : Table(string, Album);
    album_names_sorted_by_date : [..] string;
}

Album :: struct {
    name  : string;
    date  : Date;
    songs : [..] Song;
};

Date :: struct {
    year  : int;
    month : int;
    day   : int;
}

operator < :: (a: Date, b: Date) -> bool {
    if a.year  < b.year  return true;
    if a.year  > b.year  return false;
    if a.month < b.month return true;
    if a.month > b.month return false;
    if a.day   < b.day   return true;
    if a.day   > b.day   return false;
    return false;
}

parse_date :: (date_str: string) -> Date {
    date: Date;
    success: bool;
    remainder := date_str;

    date.year, success, remainder = to_integer(remainder);
    if !success return date;

    if remainder.count == 0 || remainder[0] != #char "-" return date;
    advance(*remainder, 1);
    date.month, success, remainder = to_integer(remainder);
    if !success return date;

    if remainder.count == 0 || remainder[0] != #char "-" return date;
    advance(*remainder, 1);
    date.day, success, remainder = to_integer(remainder);
    if !success return date;

    return date;
}

to_string :: (date: Date) -> string {
    if !date.year  return "";
    if !date.month return tprint("%", date.year);
    month_str := left_pad(date.month, #char "0", 2);
    if !date.day   return tprint("%-%", date.year, month_str);
    day_str := left_pad(date.day, #char "0", 2);
    return tprint("%-%-%", date.year, month_str, day_str);
}

Library_Cursor :: struct {
    positions := int.[0, 0, 0];
    selected  := 0;
}

library_cursor: Library_Cursor;

library_columns: [3] [..] string;

load_library :: () {

    assert(mpd_connection != null);
    MPD.send_list_all_meta(mpd_connection, "");
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");
    if !entity { print("Failed retrieving MPD metadata\n"); exit(1); }

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);

            mpd_artist := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
            mpd_album  := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
            mpd_title  := MPD.song_get_tag(mpd_song, .TITLE       , 0);
            mpd_date   := MPD.song_get_tag(mpd_song, .DATE        , 0);
            if mpd_artist && mpd_album && mpd_title {
                song: Song;
                song.artist = copy_from_c_string(mpd_artist);
                song.album  = copy_from_c_string(mpd_album);
                song.name   = copy_from_c_string(mpd_title);

                artist_ptr := table_find_pointer(library.artists, song.artist);
                if !artist_ptr {
                    artist: Artist;
                    artist.name = song.artist;
                    artist_ptr = table_add(*library.artists, song.artist, artist);
                    {
                        index := 0;
                        for library.artist_names_sorted {
                            if compare_nocase(artist.name, it) < 0 break;
                            index += 1;
                        }
                        array_insert_at(*library.artist_names_sorted, artist.name, index);
                    }
                }

                album_ptr := table_find_pointer(artist_ptr.albums, song.album);
                if !album_ptr {
                    album: Album;
                    album.name = song.album;
                    album.date = parse_date(to_string(mpd_date));
                    album_ptr = table_add(*artist_ptr.albums, song.album, album);

                    { // TODO: album_ptr name is confusing from above
                        index := 0;
                        for artist_ptr.album_names_sorted_by_date {
                            album_ptr := table_find_pointer(artist_ptr.albums, it);
                            assert(album_ptr != null);
                            if album.date < album_ptr.date break;
                            index += 1;
                        }
                        array_insert_at(*artist_ptr.album_names_sorted_by_date, album.name, index);
                    }
                }

                song.track = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK, 0));
                song.uri   = copy_from_c_string(MPD.song_get_uri(mpd_song));
                array_add(*album_ptr.songs, song);
            } else {
                // print("skipping: '%', '%', '%'\n", mpd_artist, to_string(mpd_album), to_string(mpd_title));
            }
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    array_resize(*library_columns[0], library.artist_names_sorted.count);
    for library.artist_names_sorted library_columns[0][it_index] = it;

    first_artist := table_find_pointer(library.artists, library.artist_names_sorted[0]);
    array_resize(*library_columns[1], first_artist.album_names_sorted_by_date.count);
    i := 0;
    for album_name: first_artist.album_names_sorted_by_date {
        album := table_find_pointer(first_artist.albums, album_name);
        library_columns[1][it_index] = sprint("(%) %", to_string(album.date), album.name);
        if it_index == 0 {
            array_resize(*library_columns[2], album.songs.count);
            for album.songs {
                library_columns[2][it_index] = sprint("% %", left_pad(it.track, #char " ", 3), it.name);;
            }
        }
    }

    reset_temporary_storage();
}

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
    handle_errors("");
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
    handle_errors("");
    return first_id_added;
}

library_last_key_pressed: Input.Key_Code;
library_key_pressed_on_frame: Table(Input.Key_Code, u64);

library_init_keys :: () {
    table_add(*library_key_pressed_on_frame, KEY_J,                0);
    table_add(*library_key_pressed_on_frame, KEY_K,                0);
    table_add(*library_key_pressed_on_frame, KEY_L,                0);
    table_add(*library_key_pressed_on_frame, KEY_H,                0);
    table_add(*library_key_pressed_on_frame, KEY_D,                0);
    table_add(*library_key_pressed_on_frame, KEY_U,                0);
    table_add(*library_key_pressed_on_frame, .SPACEBAR,            0);
    table_add(*library_key_pressed_on_frame, .ENTER,               0);
    table_add(*library_key_pressed_on_frame, KEY_B,                0);
    table_add(*library_key_pressed_on_frame, KEY_F,                0);
    table_add(*library_key_pressed_on_frame, .LEFT_ANGLE_BRACKET,  0);
    table_add(*library_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, 0);
    table_add(*library_key_pressed_on_frame, .EQUALS_SIGN,         0);
    table_add(*library_key_pressed_on_frame, .DASH,                0);
}

library_event_loop :: (frame: u64) {

    new_cursor: Library_Cursor;
    for library_cursor.positions new_cursor.positions[it_index] = it;
    new_cursor.selected = library_cursor.selected;

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    table_set(*library_key_pressed_on_frame, KEY_J, frame);
                    library_last_key_pressed = KEY_J;
                    new_cursor.positions[new_cursor.selected] += 1;
                    if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
                    if library_cursor.selected == 1 new_cursor.positions[2] = 0;
                  case KEY_K;
                    table_set(*library_key_pressed_on_frame, KEY_K, frame);
                    library_last_key_pressed = KEY_K;
                    new_cursor.positions[new_cursor.selected] -= 1;
                    if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
                    if library_cursor.selected == 1 new_cursor.positions[2] = 0;

                  case KEY_L;
                    table_set(*library_key_pressed_on_frame, KEY_L, frame);
                    library_last_key_pressed = KEY_L;
                    new_cursor.selected += 1;
                  case KEY_H;
                    table_set(*library_key_pressed_on_frame, KEY_H, frame);
                    library_last_key_pressed = KEY_H;
                    new_cursor.selected -= 1;

                  case KEY_D;
                    table_set(*library_key_pressed_on_frame, KEY_D, frame);
                    library_last_key_pressed = KEY_D;
                    new_cursor.positions[new_cursor.selected] += ITEMS_IN_PAGE;
                    if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
                    if library_cursor.selected == 1 new_cursor.positions[2] = 0;
                  case KEY_U;
                    table_set(*library_key_pressed_on_frame, KEY_U, frame);
                    library_last_key_pressed = KEY_U;
                    new_cursor.positions[new_cursor.selected] -= ITEMS_IN_PAGE;
                    if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
                    if library_cursor.selected == 1 new_cursor.positions[2] = 0;

                  case KEY_G;
                    if it.shift_pressed {
                        new_cursor.positions[library_cursor.selected] = queue.songs.count - 1;
                    } else {
                        new_cursor.positions[library_cursor.selected] = 0;
                    }

                  case KEY_P;
                    table_set(*library_key_pressed_on_frame, KEY_P, frame);
                    handle_mpd_idle_events();
                    MPD.run_toggle_pause(mpd_connection);
                    handle_errors("");

                  case KEY_C;
                    table_set(*library_key_pressed_on_frame, KEY_C, frame);
                    handle_mpd_idle_events();
                    MPD.run_clear(mpd_connection);
                    handle_errors("");
                    update_status();

                  case KEY_O;
                    table_set(*library_key_pressed_on_frame, KEY_O, frame);
                    handle_mpd_idle_events();
                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("");
                    if !mpd_current_song break;
                    uri := to_string(MPD.song_get_uri(mpd_current_song));

                    for artist, artist_name: library.artists {
                        for album, album_name: artist.albums {
                            for song, song_index: album.songs {
                                if song.uri == uri {
                                    artist_found, artist_index := array_find(library.artist_names_sorted, artist_name);
                                    if !artist_found break artist;
                                    artist_ptr := table_find_pointer(library.artists, artist_name);
                                    album_found, album_index := array_find(artist_ptr.album_names_sorted_by_date, album_name);
                                    if !album_found break artist;
                                    new_cursor.positions[0] = artist_index;
                                    new_cursor.positions[1] = album_index;
                                    new_cursor.positions[2] = song_index;
                                    new_cursor.selected     = 2;
                                }
                            }
                        }
                    }

                  case .SPACEBAR;
                    table_set(*library_key_pressed_on_frame, .SPACEBAR, frame);
                    library_last_key_pressed = .SPACEBAR;
                    handle_mpd_idle_events();
                    if library_cursor.selected == {
                      case 0;
                        add_artist_to_queue(library.artist_names_sorted[library_cursor.positions[0]]);
                      case 1;
                        artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
                        add_album_to_queue(artist.name, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
                      case 2;
                        artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
                        album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
                        MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
                    }
                    new_cursor.positions[new_cursor.selected] += 1;

                  case .ENTER;
                    table_set(*library_key_pressed_on_frame, .ENTER, frame);
                    library_last_key_pressed = .ENTER;
                    song_id_to_play: s32;

                    handle_mpd_idle_events();
                    if library_cursor.selected == {
                      case 0;
                        song_id_to_play = add_artist_to_queue(library.artist_names_sorted[library_cursor.positions[0]]);
                      case 1;
                        artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
                        song_id_to_play = add_album_to_queue(artist.name, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
                      case 2;
                        artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
                        album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
                        song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
                    }
                    new_cursor.positions[new_cursor.selected] += 1;

                    if song_id_to_play >= 0 { // play first song that was added
                        assert(mpd_connection != null);
                        MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                        handle_errors("");
                        update_status();
                    }

                  case KEY_B;
                    table_set(*library_key_pressed_on_frame, KEY_B, frame);
                    library_last_key_pressed = KEY_B;
                    handle_mpd_idle_events();
                    MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
                    handle_errors("");
                    update_status_time();
                  case KEY_F;
                    table_set(*library_key_pressed_on_frame, KEY_F, frame);
                    library_last_key_pressed = KEY_F;
                    handle_mpd_idle_events();
                    MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
                    handle_errors("");
                    update_status_time();

                  case .LEFT_ANGLE_BRACKET;
                    table_set(*library_key_pressed_on_frame, .LEFT_ANGLE_BRACKET, frame);
                    library_last_key_pressed = .LEFT_ANGLE_BRACKET;
                    handle_mpd_idle_events();
                    MPD.run_previous(mpd_connection);
                    handle_errors("");
                    update_status();
                  case .RIGHT_ANGLE_BRACKET;
                    table_set(*library_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, frame);
                    library_last_key_pressed = .RIGHT_ANGLE_BRACKET;
                    handle_mpd_idle_events();
                    MPD.run_next(mpd_connection);
                    handle_errors("");
                    update_status();

                  case .EQUALS_SIGN;
                    table_set(*library_key_pressed_on_frame, .EQUALS_SIGN, frame);
                    library_last_key_pressed = .EQUALS_SIGN;
                    handle_mpd_idle_events();
                    MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
                    handle_errors("");
                    update_status_volume();
                  case .DASH;
                    table_set(*library_key_pressed_on_frame, .DASH, frame);
                    library_last_key_pressed = .DASH;
                    handle_mpd_idle_events();
                    MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
                    handle_errors("");
                    update_status_volume();

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

    if Input.input_button_states[KEY_J] & .DOWN &&
       KEY_J == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_J) + KEY_HOLD_DELAY
    {
        new_cursor.positions[new_cursor.selected] += 1;
        if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
        if library_cursor.selected == 1 new_cursor.positions[2] = 0;
    } else
    if Input.input_button_states[KEY_K] & .DOWN    &&
       KEY_K == library_last_key_pressed           &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_K) + KEY_HOLD_DELAY
    {
        new_cursor.positions[new_cursor.selected] -= 1;
        if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
        if library_cursor.selected == 1 new_cursor.positions[2] = 0;
    }

    if Input.input_button_states[KEY_L] & .DOWN &&
       KEY_L == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_L) + KEY_HOLD_DELAY
    {
        new_cursor.selected += 1;
    } else
    if Input.input_button_states[KEY_H] & .DOWN &&
       KEY_H == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_H) + KEY_HOLD_DELAY
    {
        new_cursor.selected -= 1;
    }

    if Input.input_button_states[KEY_D] & .DOWN &&
       KEY_D == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_D) + KEY_HOLD_DELAY
    {
        new_cursor.positions[new_cursor.selected] += ITEMS_IN_PAGE;
        if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
        if library_cursor.selected == 1 new_cursor.positions[2] = 0;
    } else
    if Input.input_button_states[KEY_U] & .DOWN &&
       KEY_U == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_U) + KEY_HOLD_DELAY
    {
        new_cursor.positions[new_cursor.selected] -= ITEMS_IN_PAGE;
        if library_cursor.selected == 0 { new_cursor.positions[1], new_cursor.positions[2] = 0; }
        if library_cursor.selected == 1 new_cursor.positions[2] = 0;
    }

    if Input.input_button_states[Input.Key_Code.EQUALS_SIGN] & .DOWN &&
       Input.Key_Code.EQUALS_SIGN == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, Input.Key_Code.EQUALS_SIGN) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_change_volume(mpd_connection, VOLUME_CHANGE_AMOUNT);
        handle_errors("");
        update_status_volume();
    } else
    if Input.input_button_states[Input.Key_Code.DASH] & .DOWN &&
       Input.Key_Code.DASH == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, Input.Key_Code.DASH) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_change_volume(mpd_connection, -1 * VOLUME_CHANGE_AMOUNT);
        handle_errors("");
        update_status_volume();
    }

    if Input.input_button_states[Input.Key_Code.LEFT_ANGLE_BRACKET] & .DOWN &&
       Input.Key_Code.LEFT_ANGLE_BRACKET == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, Input.Key_Code.LEFT_ANGLE_BRACKET) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_previous(mpd_connection);
        handle_errors("");
        update_status();
    } else
    if Input.input_button_states[Input.Key_Code.RIGHT_ANGLE_BRACKET] & .DOWN &&
       Input.Key_Code.RIGHT_ANGLE_BRACKET == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, Input.Key_Code.RIGHT_ANGLE_BRACKET) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_next(mpd_connection);
        handle_errors("");
        update_status();
    }

    if Input.input_button_states[KEY_B] & .DOWN &&
       KEY_B == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_B) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_seek_current(mpd_connection, -1 * SEEK_SECONDS, true);
        handle_errors("");
        update_status_time();
    } else
    if Input.input_button_states[KEY_F] & .DOWN &&
       KEY_F == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, KEY_F) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        MPD.run_seek_current(mpd_connection, SEEK_SECONDS, true);
        handle_errors("");
        update_status_time();
    }

    if Input.input_button_states[Input.Key_Code.ENTER] & .DOWN &&
       Input.Key_Code.ENTER == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, Input.Key_Code.ENTER) + KEY_HOLD_DELAY
    {
        song_id_to_play: s32;

        handle_mpd_idle_events();
        if library_cursor.selected == {
          case 0;
            song_id_to_play = add_artist_to_queue(library.artist_names_sorted[library_cursor.positions[0]]);
          case 1;
            artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
            song_id_to_play = add_album_to_queue(artist.name, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
          case 2;
            artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
            album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
            song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
        }
        new_cursor.positions[new_cursor.selected] += 1;

        if song_id_to_play >= 0 { // play first song that was added
            assert(mpd_connection != null);
            MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
            handle_errors("");
            update_status();
        }
    }

    if Input.input_button_states[Input.Key_Code.SPACEBAR] & .DOWN &&
       Input.Key_Code.SPACEBAR == library_last_key_pressed        &&
       frame > <<table_find_pointer(library_key_pressed_on_frame, Input.Key_Code.SPACEBAR) + KEY_HOLD_DELAY
    {
        handle_mpd_idle_events();
        if library_cursor.selected == {
          case 0;
            add_artist_to_queue(library.artist_names_sorted[library_cursor.positions[0]]);
          case 1;
            artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
            add_album_to_queue(artist.name, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
          case 2;
            artist := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
            album  := table_find_pointer(artist.albums, artist.album_names_sorted_by_date[library_cursor.positions[1]]);
            MPD.run_add_id(mpd_connection, temp_c_string(album.songs[new_cursor.positions[2]].uri));
        }
        new_cursor.positions[new_cursor.selected] += 1;
    }

    if new_cursor.selected != library_cursor.selected {
        if new_cursor.selected < 0
            new_cursor.selected = 0;
        if new_cursor.selected >= new_cursor.positions.count
            new_cursor.selected = new_cursor.positions.count - 1;
    }

    for * new_cursor.positions {

        if (<<it) != library_cursor.positions[it_index] { // library_cursor changed
            if <<it < 0 {
                <<it = 0;
            } else if <<it >= library_columns[it_index].count {
                <<it = library_columns[it_index].count - 1;
            }

            if it_index < 1 { // update albums
                artist_name := library.artist_names_sorted[new_cursor.positions[0]];
                artist := table_find_pointer(library.artists, artist_name);
                if !artist { print("Artist '%' not found\n", artist_name); exit(1); }

                for library_columns[1] free(it);
                array_resize(*library_columns[1], artist.album_names_sorted_by_date.count);
                for album_name: artist.album_names_sorted_by_date {
                    album := table_find_pointer(artist.albums, album_name);
                    // if !album { print("Album '%' not found for artist '%'\n", album_name, artist_name); exit(1); }
                    library_columns[1][it_index] = sprint("(%) %", to_string(album.date), album.name);
                }
            }

            if it_index < 2 { // update songs
                artist_name := library.artist_names_sorted[new_cursor.positions[0]];
                artist := table_find_pointer(library.artists, artist_name);
                if !artist { print("Artist '%' not found\n", artist_name); exit(1); }

                album_name := artist.album_names_sorted_by_date[new_cursor.positions[1]];
                album := table_find_pointer(artist.albums, album_name);
                if !album { print("Album '%' not found for artist '%'\n", album_name, artist_name); exit(1); }

                for library_columns[2] free(it);
                array_resize(*library_columns[2], album.songs.count);
                for album.songs {
                   library_columns[2][it_index] = sprint("% %", left_pad(it.track, #char " ", 4), it.name);;
                }
            }
        }
    }

    library_cursor = new_cursor;
    draw_library_frame();
}


draw_library_frame :: () {
    column_width := cast(s32) display_width / 3;

    original_y := HEADER_BOTTOM - 25;
    text_padding_y :: 5;

    max_characters_in_column := (column_width - 60) / font.em_width;

    x := x_margin_size;
    {
        y := original_y;

        index_start := max(0, min(library_columns[0].count - ITEMS_IN_PAGE + 1, library_cursor.positions[0] - ITEMS_IN_PAGE/ 2 + 1));
        index_end := min(index_start + ITEMS_IN_PAGE, library_columns[0].count - 1);
        for i: index_start..index_end {
            artist := library_columns[0][i];

            text := slice(artist, 0, max_characters_in_column);
            if i == library_cursor.positions[0] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx library_cursor.selected == 0 then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width - 50, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_width;
    {
        y := original_y;

        index_start := max(0, min(library_columns[1].count - ITEMS_IN_PAGE + 1, library_cursor.positions[1] - ITEMS_IN_PAGE/ 2 + 1));
        index_end := min(index_start + ITEMS_IN_PAGE, library_columns[1].count - 1);
        for i: index_start..index_end {
            album := library_columns[1][i];

            text := slice(album, 0, max_characters_in_column);
            if i == library_cursor.positions[1] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx library_cursor.selected == 1 then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width - 50, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }

    x += column_width;
    {
        y := original_y;

        index_start := max(0, min(library_columns[2].count - ITEMS_IN_PAGE + 1, library_cursor.positions[2] - ITEMS_IN_PAGE/ 2 + 1));
        index_end := min(index_start + ITEMS_IN_PAGE, library_columns[2].count - 1);
        for i: index_start..index_end {
            song := library_columns[2][i];

            text := slice(song, 0, max_characters_in_column);
            if i == library_cursor.positions[2] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx library_cursor.selected == 2 then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= text_padding_y + font.character_height;
        }
    }
}
