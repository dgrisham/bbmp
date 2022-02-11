#import "Hash_Table";
#import "Unicode";

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

            mpd_artist   := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
            mpd_album    := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
            mpd_title    := MPD.song_get_tag(mpd_song, .TITLE       , 0);
            mpd_date     := MPD.song_get_tag(mpd_song, .DATE        , 0);
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

                song.track    = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK, 0));
                song.uri      = copy_from_c_string(MPD.song_get_uri(mpd_song));
                song.duration = MPD.song_get_duration(mpd_song);
                array_add(*album_ptr.songs, song);
            } else {
                // print("skipping: '%', '%', '%'\n", mpd_artist, to_string(mpd_album), to_string(mpd_title));
            }
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    // array_resize(*library_columns[0], library.artist_names_sorted.count);
    // for library.artist_names_sorted library_columns[0][it_index] = it;

    // first_artist := table_find_pointer(library.artists, library.artist_names_sorted[0]);
    // array_resize(*library_columns[1], first_artist.album_names_sorted_by_date.count);
    // i := 0;
    // for album_name: first_artist.album_names_sorted_by_date {
    //     album := table_find_pointer(first_artist.albums, album_name);
    //     library_columns[1][it_index] = sprint("(%) %", to_string(album.date), album.name);
    //     if it_index == 0 {
    //         array_resize(*library_columns[2], album.songs.count);
    //         array_resize(*library_columns[3], album.songs.count);
    //         for album.songs {
    //            library_columns[2][it_index] = sprint("%. %", left_pad(it.track, #char " ", 4), it.name);
    //            library_columns[3][it_index] = seconds_to_time_string(it.duration);
    //         }
    //     }
    // }
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
    table_set(*library_key_pressed_on_frame, .J,      0);
    table_set(*library_key_pressed_on_frame, .K,      0);
    table_set(*library_key_pressed_on_frame, .L,      0);
    table_set(*library_key_pressed_on_frame, .H,      0);
    table_set(*library_key_pressed_on_frame, .CTRL_D, 0);
    table_set(*library_key_pressed_on_frame, .CTRL_U, 0);
    table_set(*library_key_pressed_on_frame, .SPACE,  0);
}

library_event_loop :: (frame: u64, header_bottom: int) {

    items_in_page := (header_bottom - 2 * Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);

    move_selected_cursor :: (amount: int) #expand {
        `library_cursor.positions[library_cursor.selected] += amount;
        if library_cursor.selected == 0 { `library_cursor.positions[1], `library_cursor.positions[2] = 0; }
        if library_cursor.selected == 1 `library_cursor.positions[2] = 0;
    }
    move_selected_cursor_down          :: () #expand { move_selected_cursor(1);              }
    move_selected_cursor_up            :: () #expand { move_selected_cursor(-1);             }
    move_selected_cursor_one_page_down :: () #expand { move_selected_cursor( items_in_page); }
    move_selected_cursor_one_page_up   :: () #expand { move_selected_cursor(-items_in_page); }

    move_selected_cursor_left  :: () #expand { `library_cursor.selected -= 1; }
    move_selected_cursor_right :: () #expand { `library_cursor.selected += 1; }

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
            song_id_to_play = MPD.run_add_id(mpd_connection, temp_c_string(album.songs[library_cursor.positions[2]].uri));
        }
        `library_cursor.positions[library_cursor.selected] += 1;

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
                    last_library_key_pressed = .H;
                    table_set(*library_key_pressed_on_frame, .H, frame);
                    move_selected_cursor_left();
                    break it;
                  case KEY_L;
                    last_library_key_pressed = .L;
                    table_set(*library_key_pressed_on_frame, .L, frame);
                    move_selected_cursor_right();
                    break it;

                  case KEY_J;
                    last_library_key_pressed = .J;
                    table_set(*library_key_pressed_on_frame, .J, frame);
                    move_selected_cursor_down();
                    break it;
                  case KEY_K;
                    last_library_key_pressed = .K;
                    table_set(*library_key_pressed_on_frame, .K, frame);
                    move_selected_cursor_up();
                    break it;

                  case KEY_D;
                    if it.ctrl_pressed {
                        last_library_key_pressed = .CTRL_D;
                        table_set(*library_key_pressed_on_frame, .CTRL_D, frame);
                        move_selected_cursor_one_page_down();
                        break it;
                    }
                  case KEY_U;
                    if it.ctrl_pressed {
                        last_library_key_pressed = .CTRL_U;
                        table_set(*library_key_pressed_on_frame, .CTRL_U, frame);
                        move_selected_cursor_one_page_up();
                        break it;
                    }

                  case KEY_G;
                    if it.shift_pressed {
                        if library_cursor.selected == {
                            case 0;
                              library_cursor.positions[0] = library.artists.count - 1;
                            case 1;
                              artist_ptr := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
                              assert(artist_ptr != null);
                              library_cursor.positions[1] = artist_ptr.albums.count - 1;
                            case 2;
                              artist_ptr := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
                              assert(artist_ptr != null);
                              album_ptr := table_find_pointer(artist_ptr.albums, artist_ptr.album_names_sorted_by_date[library_cursor.positions[1]]);
                              library_cursor.positions[2] = album_ptr.songs.count - 1;
                        }
                    } else {
                        library_cursor.positions[library_cursor.selected] = 0;
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
                                    library_cursor.positions[0] = artist_index;
                                    library_cursor.positions[1] = album_index;
                                    library_cursor.positions[2] = song_index;
                                    library_cursor.selected     = 2;
                                }
                            }
                        }
                    }
                    break it;

                  case .SPACEBAR;
                    last_library_key_pressed = .SPACE;
                    table_set(*library_key_pressed_on_frame, .SPACE, frame);
                    add_selection_to_queue();
                    break it;

                  case .ENTER;
                    last_library_key_pressed = .ENTER;
                    table_set(*library_key_pressed_on_frame, .ENTER, frame);
                    add_selection_to_queue_and_play();
                    break it;

                  // case;
                  //   print("key_code: %\n", it.key_code);
                }
            }

        }
    }

    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .J)      move_selected_cursor_down();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .K)      move_selected_cursor_up();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .H)      move_selected_cursor_left();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .L)      move_selected_cursor_right();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .CTRL_D) move_selected_cursor_one_page_down();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .CTRL_U) move_selected_cursor_one_page_up();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .SPACE)  add_selection_to_queue();

    if library_cursor.selected < 0 {
        library_cursor.selected = 0;
    } else if library_cursor.selected > library_cursor.positions.count - 1 {
        library_cursor.selected = library_cursor.positions.count - 1;
    }

    if library_cursor.selected == {
        case 0;
          if library_cursor.positions[0] < 0 {
              library_cursor.positions[0] = 0;
          } else
          if library_cursor.positions[0] > library.artists.count - 1 {
            library_cursor.positions[0] = library.artists.count - 1;
          }
        case 1;
          artist_ptr := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
          assert(artist_ptr != null);
          if library_cursor.positions[1] < 0 {
              library_cursor.positions[1] = 0;
          } else
          if library_cursor.positions[1] > artist_ptr.albums.count - 1 {
            library_cursor.positions[1] = artist_ptr.albums.count - 1;
          }
        case 2;
          artist_ptr := table_find_pointer(library.artists, library.artist_names_sorted[library_cursor.positions[0]]);
          assert(artist_ptr != null);
          album_ptr := table_find_pointer(artist_ptr.albums, artist_ptr.album_names_sorted_by_date[library_cursor.positions[1]]);
          if library_cursor.positions[2] < 0 {
              library_cursor.positions[2] = 0;
          } else
          if library_cursor.positions[2] > album_ptr.songs.count - 1 {
            library_cursor.positions[2] = album_ptr.songs.count - 1;
          }
    }

    if library_cursor.selected != library_cursor.selected {
        if library_cursor.selected < 0
            library_cursor.selected = 0;
        if library_cursor.selected >= library_cursor.positions.count
            library_cursor.selected = library_cursor.positions.count - 1;
    }

    display_columns := update_library_display_columns(items_in_page);
    draw_library_frame(header_bottom, display_columns);
}

column_widths    : [3] s32;
rectangle_widths : [3] s32;

Display_Text :: struct {
    text     : string;
    selected : bool;
}

update_library_display_columns :: (items_in_page: int) -> [3] [..] Display_Text {

    display_columns: [3] [..] Display_Text;
    display_columns[0].allocator = __temporary_allocator;
    display_columns[1].allocator = __temporary_allocator;
    display_columns[2].allocator = __temporary_allocator;

    column_widths[0] = cast(s32)(1 / 3.0 * display_width());
    column_widths[1] = cast(s32)(1 / 3.0 * display_width());
    column_widths[2] = cast(s32)(1 / 3.0 * display_width());

    rectangle_widths[0] = column_widths[0] - 50;
    rectangle_widths[1] = column_widths[1] - 50;
    rectangle_widths[2] = column_widths[2];

    selected_artist_index := library_cursor.positions[0];
    {
        index_start := max(0, min(library.artists.count - items_in_page + 1, selected_artist_index  - items_in_page/ 2 + 1));
        index_end   := min(index_start + items_in_page, library.artists.count - 1);
        array_reserve(*display_columns[0], index_end - index_start + 1);

        column_width := column_widths[0];
        rectangle_width := column_width - 50;
        max_characters_in_column := rectangle_width / font.em_width - 2;

        for i: index_start..index_end {
            display_text: Display_Text;
            display_text.text = copy_temporary_string(slice(library.artist_names_sorted[i], 0, max_characters_in_column));
            display_text.selected = selected_artist_index == i;
            array_add(*display_columns[0], display_text);
        }
    }

    selected_album_index := library_cursor.positions[1];
    selected_artist      := table_find_pointer(library.artists, library.artist_names_sorted[selected_artist_index]);
    {
        index_start := max(0, min(selected_artist.albums.count - items_in_page + 1, selected_album_index - items_in_page/ 2 + 1));
        index_end   := min(index_start + items_in_page, selected_artist.albums.count - 1);
        array_reserve(*display_columns[1], index_end - index_start + 1);

        column_width    := column_widths[1];
        rectangle_width := column_width - 50;
        max_characters_in_column := rectangle_width / font.em_width - 2;

        for i: index_start..index_end {
            display_text: Display_Text;
            album := table_find_pointer(selected_artist.albums, selected_artist.album_names_sorted_by_date[i]);
            assert(album != null);
            display_text.text = copy_temporary_string(slice(tprint("(%) %", to_string(album.date), album.name), 0, max_characters_in_column));

            display_text.selected = selected_album_index == i;
            array_add(*display_columns[1], display_text);
        }
    }

    selected_song_index := library_cursor.positions[2];
    selected_album      := table_find_pointer(selected_artist.albums, selected_artist.album_names_sorted_by_date[selected_album_index]);
    {
        index_start := max(0, min(selected_album.songs.count - items_in_page + 1, selected_song_index - items_in_page/ 2 + 1));
        index_end   := min(index_start + items_in_page, selected_album.songs.count - 1);
        array_reserve(*display_columns[2], index_end - index_start + 1);

        column_width    := column_widths[2];
        rectangle_width := column_width;
        max_characters_in_column := rectangle_width / font.em_width - 2;

        for i: index_start..index_end {
            song := selected_album.songs[i];

            padded_track := left_pad(song.track, #char " ", 4);
            duration_time_string := seconds_to_time_string(song.duration, __temporary_allocator);
            sliced_title := slice(song.name, 0, max_characters_in_column - padded_track.count - duration_time_string.count);

            track_and_title := tprint("%. %", padded_track, sliced_title);
            duration := left_pad(duration_time_string, #char " ", max_characters_in_column - get_unicode_length(track_and_title));

            display_text: Display_Text;
            display_text.text = tprint("% %", track_and_title, duration);
            display_text.selected = selected_song_index == i;
            array_add(*display_columns[2], display_text);
        }
    }

    return display_columns;
}

get_unicode_length :: (s: string) -> int {
    length := 0;
    i := 0;
    while i < s.count {
        utf8_bytes := 1 + trailingBytesForUTF8[s.data[i]];
        length += 1;
        i += utf8_bytes;
    }
    return length;
}

draw_library_frame :: (header_bottom: int, library_display_columns: [3] [..] Display_Text) {
    top := header_bottom - 25;

    x := X_MARGIN_SIZE;
    for column_index: 0..library_display_columns.count - 1 { // draw all but the last column (song duration)
        y := top;
        column_width    := column_widths[column_index];
        rectangle_width := rectangle_widths[column_index];

        for display_text: library_display_columns[column_index] {
            if display_text.selected {
                Simp.immediate_begin();
                Simp.set_shader_for_color();
                color := ifx library_cursor.selected == column_index then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);

                Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + rectangle_width, cast(float)y + font.character_height, color);
                Simp.immediate_flush();
                Simp.draw_text(font, x, y, display_text.text, rgba(0,0,0,1));
            } else {
                Simp.draw_text(font, x, y, display_text.text, rgba(1,1,1,1));
            }

            y -= TEXT_PADDING_Y + font.character_height;
        }
        x += column_width;
    }
}
