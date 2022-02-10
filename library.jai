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
    handle_errors("Adding album's songs to queue");
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
    handle_errors("Adding artist's songs to queue");
    return first_id_added;
}

last_library_key_pressed: Key;
library_key_pressed_on_frame: Table(Key, u64);

library_init_repeatable_keys :: () {
    table_set(*library_key_pressed_on_frame, .J,     0);
    table_set(*library_key_pressed_on_frame, .K,     0);
    table_set(*library_key_pressed_on_frame, .L,     0);
    table_set(*library_key_pressed_on_frame, .H,     0);
    table_set(*library_key_pressed_on_frame, .D,     0);
    table_set(*library_key_pressed_on_frame, .U,     0);
    table_set(*library_key_pressed_on_frame, .SPACE, 0);
}

library_event_loop :: (frame: u64, header_bottom: int) {

    items_in_page := (header_bottom - 2 * Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);

    new_cursor: Library_Cursor;
    for library_cursor.positions new_cursor.positions[it_index] = it;
    new_cursor.selected = library_cursor.selected;

    move_selected_cursor :: (amount: int) #expand {
        `new_cursor.positions[library_cursor.selected] += amount;
        if library_cursor.selected == 0 { `new_cursor.positions[1], `new_cursor.positions[2] = 0; }
        if library_cursor.selected == 1 `new_cursor.positions[2] = 0;
    }
    move_selected_cursor_down          :: () #expand { move_selected_cursor(1);              }
    move_selected_cursor_up            :: () #expand { move_selected_cursor(-1);             }
    move_selected_cursor_one_page_down :: () #expand { move_selected_cursor( items_in_page); }
    move_selected_cursor_one_page_up   :: () #expand { move_selected_cursor(-items_in_page); }

    move_selected_cursor_left  :: () #expand { `new_cursor.selected -= 1; }
    move_selected_cursor_right :: () #expand { `new_cursor.selected += 1; }

    add_selection_to_queue :: () -> s32 #expand {
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
        `new_cursor.positions[library_cursor.selected] += 1;

        return song_id_to_play;
    }

    add_selection_to_queue_and_play :: () #expand {
        first_song_id_added := add_selection_to_queue();
        if first_song_id_added >= 0 {
            assert(mpd_connection != null);
            MPD.run_play_id(mpd_connection, cast(u32)first_song_id_added);
            handle_errors("Playing first song in group added to queue");
            update_status();
        }
    }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_H;
                    table_set(*library_key_pressed_on_frame, .H, frame);
                    last_library_key_pressed = .H;
                    move_selected_cursor_left();
                    break it;
                  case KEY_L;
                    table_set(*library_key_pressed_on_frame, .L, frame);
                    last_library_key_pressed = .L;
                    move_selected_cursor_right();
                    break it;

                  case KEY_J;
                    table_set(*library_key_pressed_on_frame, .J, frame);
                    last_library_key_pressed = .J;
                    move_selected_cursor_down();
                    break it;
                  case KEY_K;
                    table_set(*library_key_pressed_on_frame, .K, frame);
                    last_library_key_pressed = .K;
                    move_selected_cursor_up();
                    break it;

                  case KEY_D;
                    table_set(*library_key_pressed_on_frame, .D, frame);
                    last_library_key_pressed = .D;
                    move_selected_cursor_one_page_down();
                    break it;
                  case KEY_U;
                    table_set(*library_key_pressed_on_frame, .U, frame);
                    last_library_key_pressed = .U;
                    move_selected_cursor_one_page_up();
                    break it;

                  case KEY_G;
                    if it.shift_pressed {
                        new_cursor.positions[library_cursor.selected] = library_columns[library_cursor.selected].count - 1;
                    } else {
                        new_cursor.positions[library_cursor.selected] = 0;
                    }
                    break it;

                  case KEY_O;
                    handle_mpd_idle_events();

                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("Getting current song");
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
                    break it;

                  case .SPACEBAR;
                    table_set(*library_key_pressed_on_frame, .SPACE, frame);
                    last_library_key_pressed = .SPACE;
                    add_selection_to_queue();
                    break it;

                  case .ENTER;
                    table_set(*library_key_pressed_on_frame, .ENTER, frame);
                    last_library_key_pressed = .ENTER;
                    add_selection_to_queue_and_play();
                    break it;

                  // case;
                  //   print("key_code: %\n", it.key_code);
                }
            }

        }
    }

    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .J)     move_selected_cursor_down();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .K)     move_selected_cursor_up();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .H)     move_selected_cursor_left();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .L)     move_selected_cursor_right();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .D)     move_selected_cursor_one_page_down();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .U)     move_selected_cursor_one_page_up();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .SPACE) add_selection_to_queue();

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
    draw_library_frame(header_bottom, items_in_page);
}


draw_library_frame :: (header_bottom: int, items_in_page: int) {
    column_width := cast(s32) display_width() / 3;

    top := header_bottom - 25;

    max_characters_in_column := (column_width - 60) / font.em_width;

    x := X_MARGIN_SIZE;
    for column: library_columns {
        y := top;

        index_start := max(0, min(column.count - items_in_page + 1, library_cursor.positions[it_index] - items_in_page/ 2 + 1));
        index_end := min(index_start + items_in_page, library_columns[it_index].count - 1);
        for i: index_start..index_end {
            text := slice(library_columns[it_index][i], 0, max_characters_in_column);
            if i == library_cursor.positions[it_index] {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx library_cursor.selected == it_index then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);

                rectangle_end := ifx it_index < library_columns.count - 1
                                 then cast(float)x + column_width - 50 // leave some space between this rectangle and the next
                                 else cast(float)x + column_width;     // draw the rightmost rectangle all the way to the end
                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, rectangle_end, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, text, rgba(1,1,1,1));
            }

            y -= TEXT_PADDING_Y + font.character_height;
        }
        x += column_width;
    }
}
