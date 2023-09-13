#scope_file

#import "Basic";
#import "File_Utilities";
#import "Hash_Table";
#import "Math";
#import "String";
#import "Unicode";

#import "common";

MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";
Input :: #import "Input";

Queue :: #import "queue";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_search_query_key_pressed: Key;
search_query_key_pressed_on_frame: Table(Key, u64);

search_query: Search_Query;

inputting_search_query := false;

cursor: struct {
    positions := int.[0, 0, 0];
    selected  := 0;
};

log_data :: Log_Data.{"library", false};

#scope_export

load :: (mpd_connection: *MPD.connection) -> Library_Data {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    library := New(Library_Data);
    initialize_search_query(*search_query);
    if !mpd_connection return library;

    MPD.send_list_all_meta(mpd_connection, "");
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");
    if !entity { log("No data loaded from MPD"); return library; }

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song := MPD.entity_get_song(entity);

            mpd_artist := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
            if !mpd_artist {
                mpd_artist = MPD.song_get_tag(mpd_song, .ARTIST, 0);
            }
            mpd_album  := MPD.song_get_tag(mpd_song, .ALBUM, 0);
            mpd_title  := MPD.song_get_tag(mpd_song, .TITLE, 0);
            mpd_date   := MPD.song_get_tag(mpd_song, .DATE,  0);
            if mpd_artist && mpd_album && mpd_title {
                song := New(Song);
                song.artist   = copy_from_c_string(mpd_artist);
                song.album    = copy_from_c_string(mpd_album);
                song.name     = copy_from_c_string(mpd_title);
                song.track    = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK, 0));
                song.uri      = copy_from_c_string(MPD.song_get_uri(mpd_song));
                song.duration = MPD.song_get_duration(mpd_song);

                artist_ptr := table_find_pointer(*library.artists, song.artist);
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
                    library.stats.number_of_artists += 1;
                }

                album_ptr := table_find_pointer(*artist_ptr.albums, song.album);
                if !album_ptr {
                    album: Album;
                    album.name        = song.album;
                    album.artist_name = song.artist;
                    album.date        = parse_date(to_string(mpd_date));
                    album.directory   = path_strip_filename(song.uri);

                    for cover_name: string.["cover.jpg", "cover.png"] {
                        path := tprint("%/%2%3", config.mpd_library_directory, album.directory, cover_name);
                        if file_exists(path) {
                            album.cover_path = copy_string(path);
                            break;
                        }
                    }

                    album_ptr = table_add(*artist_ptr.albums, song.album, album);

                    { // TODO: album_ptr name is confusing from above
                        index := 0;
                        for artist_ptr.album_names_sorted_by_date {
                            album_ptr := table_find_pointer(*artist_ptr.albums, it);
                            assert(album_ptr != null);
                            if album.date < album_ptr.date break;
                            index += 1;
                        }
                        array_insert_at(*artist_ptr.album_names_sorted_by_date, album.name, index);
                    }
                    library.stats.number_of_albums += 1;
                }

                array_add(*album_ptr.songs, song);
                table_set(*library.songs_by_uri, song.uri, song);

                library.stats.number_of_songs += 1;
            }
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    return library;
}

event_loop :: (mpd_connection: *MPD.connection, library: Library_Data, queue: *Queue.Data, frame: u64, fonts: Fonts, display_width: s32, header_bottom: int) -> bool {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    items_in_page := (header_bottom - Y_MARGIN_SIZE) / (fonts.regular.character_height + TEXT_PADDING_Y);

    move_selected_cursor :: (amount: int) #expand {
        `cursor.positions[cursor.selected] += amount;
        if cursor.selected == 0 { `cursor.positions[1], `cursor.positions[2] = 0; }
        if cursor.selected == 1 `cursor.positions[2] = 0;
    }
    move_selected_cursor_up             :: () #expand { move_selected_cursor(-1);                 }
    move_selected_cursor_down           :: () #expand { move_selected_cursor(+1);                 }
    move_selected_cursor_half_page_up   :: () #expand { move_selected_cursor(-items_in_page / 2); }
    move_selected_cursor_half_page_down :: () #expand { move_selected_cursor(+items_in_page / 2); }

    move_selected_cursor_left  :: () #expand { `cursor.selected -= 1; }
    move_selected_cursor_right :: () #expand { `cursor.selected += 1; }

    add_selection_to_queue_and_increment_cursor :: () -> s32 #expand {
        if !mpd_connection {
            log("No connection to MPD, cannot add song to queue", flags=.ERROR);
            return -1;
        }

        if cursor.selected == {
          case 0;
            add_artist_to_queue(`library, `library.artist_names_sorted[cursor.positions[0]]);
          case 1;
            artist, artist_found := table_find(*`library.artists, `library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_found, "Artist not found while adding queue album");
            add_album_to_queue(`library, artist.name, artist.album_names_sorted_by_date[cursor.positions[1]]);
          case 2;
            artist, artist_found := table_find(*`library.artists, `library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_found, "Artist not found while toggling queue song");
            album, album_found := table_find(*artist.albums, artist.album_names_sorted_by_date[cursor.positions[1]]);
            assert(album_found, "Album not found while toggling queue song");

            song_uri := album.songs[cursor.positions[2]].uri;

            ids := table_find_multiple(*`queue.queued_URIs, song_uri);
            if ids.count {
                for id: ids {
                    MPD.run_delete_id(mpd_connection, id);
                    handle_errors("Deleting song from queue");
                }
            } else {
                MPD.run_add_id(mpd_connection, to_c_string(song_uri));
                handle_errors("Adding song to queue");
            }
        }

        Queue.update(`mpd_connection, `library, `queue);
        `cursor.positions[cursor.selected] += 1;
    }

    add_selection_to_queue_and_play :: () #expand {
        if !mpd_connection {
            log("No connection to MPD, cannot add song to queue", flags=.ERROR);
            return;
        }

        id: int;
        if cursor.selected == {
          case 0;
            id = add_artist_to_queue(`library, `library.artist_names_sorted[cursor.positions[0]]);
          case 1;
            artist, artist_found := table_find(*`library.artists, `library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_found, "Artist not found while adding queue album");
            id = add_album_to_queue(`library, artist.name, artist.album_names_sorted_by_date[cursor.positions[1]]);
          case 2;
            artist, artist_found := table_find(*`library.artists, `library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_found, "Artist not found while toggling queue song");
            album, album_found := table_find(*artist.albums, artist.album_names_sorted_by_date[cursor.positions[1]]);
            assert(album_found, "Album not found while toggling queue song");

            song_uri := album.songs[cursor.positions[2]].uri;
            id = MPD.run_add_id(mpd_connection, to_c_string(song_uri));
        }
        if id > 0 {
            MPD.run_play_id(mpd_connection, cast(u32)id);
            handle_errors("Playing song added to queue");
        }

        Queue.update(`mpd_connection, `library, `queue);
        `cursor.positions[cursor.selected] += 1;
    }

    move_cursor_to_next_search_result :: () #expand {
        if search_query.str == "" return;

        if cursor.selected == {
          case 0;
            for i: 0..(library.artist_names_sorted.count - 1) {
                artist_index := (i + cursor.positions[0] + 1) % library.artist_names_sorted.count;
                artist := library.artist_names_sorted[artist_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(artist, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[0] = artist_index;
                    `cursor.positions[1] = 0;
                    `cursor.positions[2] = 0;
                    break;
                }
            }
          case 1;
            artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_ptr != null);
            for i: 0..(artist_ptr.album_names_sorted_by_date.count - 1) {
                album_index := (i + cursor.positions[1] + 1) % artist_ptr.album_names_sorted_by_date.count;
                album := artist_ptr.album_names_sorted_by_date[album_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(album, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[1] = album_index;
                    `cursor.positions[2] = 0;
                    break;
                }
            }
          case 2;
            artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_ptr != null);
            album_ptr := table_find_pointer(*artist_ptr.albums, artist_ptr.album_names_sorted_by_date[cursor.positions[1]]);
            assert(album_ptr != null);
            for i: 0..(album_ptr.songs.count - 1) {
                song_index := (i + cursor.positions[2] + 1) % album_ptr.songs.count;
                song := album_ptr.songs[song_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(song.name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[2] = song_index;
                    break;
                }
            }
        }
    }
    move_cursor_to_prev_search_result :: () #expand {
        if search_query.str == "" return;

        if cursor.selected == {
          case 0;
            for < i: (library.artist_names_sorted.count - 1)..0 {
                artist_index := (i + cursor.positions[0]) % library.artist_names_sorted.count;
                artist := library.artist_names_sorted[artist_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(artist, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[0] = artist_index;
                    `cursor.positions[1] = 0;
                    `cursor.positions[2] = 0;
                    break;
                }
            }
          case 1;
            artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_ptr != null);
            for < i: (artist_ptr.album_names_sorted_by_date.count - 1)..0 {
                album_index := (i + cursor.positions[1]) % artist_ptr.album_names_sorted_by_date.count;
                album := artist_ptr.album_names_sorted_by_date[album_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(album, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[1] = album_index;
                    `cursor.positions[2] = 0;
                    break;
                }
            }
          case 2;
            artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
            assert(artist_ptr != null);
            album_ptr := table_find_pointer(*artist_ptr.albums, artist_ptr.album_names_sorted_by_date[cursor.positions[1]]);
            assert(album_ptr != null);
            for < i: (album_ptr.songs.count - 1)..0 {
                song_index := (i + cursor.positions[2]) % album_ptr.songs.count;
                song := album_ptr.songs[song_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(song.name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[2] = song_index;
                    break;
                }
            }
        }
    }

    if !inputting_search_query {
        for Input.events_this_frame {
            if it.type == {
              case .KEYBOARD;
                if it.key_pressed {
                    if it.key_code == {

                      case KEY_H;
                        last_key_pressed = .H;
                        table_set(*key_pressed_on_frame, .H, frame);
                        move_selected_cursor_left();
                        break it;
                      case KEY_L;
                        last_key_pressed = .L;
                        table_set(*key_pressed_on_frame, .L, frame);
                        move_selected_cursor_right();
                        break it;

                      case KEY_J;
                        last_key_pressed = .J;
                        table_set(*key_pressed_on_frame, .J, frame);
                        move_selected_cursor_down();
                        break it;
                      case KEY_K;
                        last_key_pressed = .K;
                        table_set(*key_pressed_on_frame, .K, frame);
                        move_selected_cursor_up();
                        break it;

                      case KEY_D;
                        if it.ctrl_pressed {
                            last_key_pressed = .CTRL_D;
                            table_set(*key_pressed_on_frame, .CTRL_D, frame);
                            move_selected_cursor_half_page_down();
                            break it;
                        }
                      case KEY_U;
                        if it.ctrl_pressed {
                            last_key_pressed = .CTRL_U;
                            table_set(*key_pressed_on_frame, .CTRL_U, frame);
                            move_selected_cursor_half_page_up();
                            break it;
                        }

                      case KEY_G;
                        if cursor.selected == {
                            case 0;
                              if it.shift_pressed {
                                  cursor.positions[0] = max(0, library.artists.count - 1);
                              } else {
                                  cursor.positions[0] = 0;
                              }
                              cursor.positions[1] = 0;
                              cursor.positions[2] = 0;
                            case 1;
                              if it.shift_pressed {
                                  artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
                                  assert(artist_ptr != null);
                                  cursor.positions[1] = max(0, artist_ptr.albums.count - 1);
                              } else {
                                cursor.positions[1] = 0;
                              }
                              cursor.positions[2] = 0;
                            case 2;
                              if it.shift_pressed {
                                  artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
                                  assert(artist_ptr != null);
                                  album_ptr := table_find_pointer(*artist_ptr.albums, artist_ptr.album_names_sorted_by_date[cursor.positions[1]]);
                                  cursor.positions[2] = max(0, album_ptr.songs.count - 1);
                              } else {
                                  cursor.positions[2] = 0;
                              }
                        }
                        break it;

                      case KEY_O;
                        mpd_current_song := MPD.run_current_song(mpd_connection);
                        handle_errors("Getting current song");
                        if !mpd_current_song break;

                        uri := to_string(MPD.song_get_uri(mpd_current_song));
                        song, song_found := table_find(*library.songs_by_uri, uri);
                        if !song_found break it;

                        artist_index_found, artist_index := array_find(library.artist_names_sorted, song.artist);
                        if !artist_index_found break it;

                        artist_ptr, artist_found := table_find(*library.artists, song.artist);
                        if !artist_found break it;

                        album_index_found, album_index := array_find(artist_ptr.album_names_sorted_by_date, song.album);
                        if !album_index_found break it;

                        album_ptr, album_found := table_find(*artist_ptr.albums, song.album);
                        if !album_found break it;

                        song_index: int;
                        song_index_found := false;
                        for album_ptr.songs {
                            if it.uri == song.uri {
                                song_index = it_index;
                                song_index_found = true;
                            }
                        }
                        if !song_index_found break it;

                        cursor.positions[0] = artist_index;
                        cursor.positions[1] = album_index;
                        cursor.positions[2] = song_index;
                        cursor.selected     = 2;

                        break it;

                      case .SPACEBAR;
                        last_key_pressed = .SPACE;
                        table_set(*key_pressed_on_frame, .SPACE, frame);
                        add_selection_to_queue_and_increment_cursor();
                        break it;

                      case .ENTER;
                        last_key_pressed = .ENTER;
                        table_set(*key_pressed_on_frame, .ENTER, frame);
                        add_selection_to_queue_and_play();
                        break it;

                      case .FORWARD_SLASH;
                        inputting_search_query = true;
                        search_query.str.count = 0;
                        break it;

                      case KEY_N;
                        if it.shift_pressed {
                            last_key_pressed = .SHIFT_N;
                            table_set(*key_pressed_on_frame, .SHIFT_N, frame);
                            move_cursor_to_prev_search_result();
                        } else {
                            last_key_pressed = .N;
                            table_set(*key_pressed_on_frame, .N, frame);
                            move_cursor_to_next_search_result();
                        }
                        break it;
                    }
                }
            }
        }

        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       move_selected_cursor_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       move_selected_cursor_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .H)       move_selected_cursor_left();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .L)       move_selected_cursor_right();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  move_selected_cursor_half_page_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  move_selected_cursor_half_page_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SPACE)   add_selection_to_queue_and_increment_cursor();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .N)       move_cursor_to_next_search_result();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_N) move_cursor_to_prev_search_result();
    } else {

        /*****************************
        * user entering search query *
        *****************************/

        move_cursor_to_first_search_result :: () #expand {
            if search_query.str == "" return;

            if cursor.selected == {
              case 0;
                for artist, artist_index: library.artist_names_sorted {
                    match := true;
                    for s: split(search_query.str, SPACE) {
                        if !contains_nocase(artist, s) {
                            match = false;
                            break;
                        }
                    }
                    if match {
                        `cursor.positions[0] = artist_index;
                        `cursor.positions[1] = 0;
                        `cursor.positions[2] = 0;
                        break;
                    }
                }
              case 1;
                artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
                assert(artist_ptr != null);
                for album, album_index: artist_ptr.album_names_sorted_by_date {
                    match := true;
                    for s: split(search_query.str, SPACE) {
                        if !contains_nocase(album, s) {
                            match = false;
                            break;
                        }
                    }
                    if match {
                        `cursor.positions[1] = album_index;
                        `cursor.positions[2] = 0;
                        break;
                    }
                }
              case 2;
                artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
                assert(artist_ptr != null);
                album_ptr := table_find_pointer(*artist_ptr.albums, artist_ptr.album_names_sorted_by_date[cursor.positions[1]]);
                assert(album_ptr != null);
                for song, song_index: album_ptr.songs {
                    match := true;
                    for s: split(search_query.str, SPACE) {
                        if !contains_nocase(song.name, s) {
                            match = false;
                            break;
                        }
                    }
                    if match {
                        `cursor.positions[2] = song_index;
                        break;
                    }
                }
            }
        }

        for Input.events_this_frame {
            if it.type == {

              case .TEXT_INPUT;
                if append_utf32_to_search_query(*search_query, it.utf32) {
                    move_cursor_to_first_search_result();
                }
                break it;

              case .KEYBOARD;
                if it.key_pressed {
                    if it.key_code == {

                      case .BACKSPACE;
                        last_search_query_key_pressed = .BACKSPACE;
                        table_set(*search_query_key_pressed_on_frame, .BACKSPACE, frame);
                        backspace_search_query(*search_query);
                        move_cursor_to_first_search_result();
                        break it;

                      case KEY_U;
                        if it.ctrl_pressed {
                            last_search_query_key_pressed = .CTRL_U;
                            search_query.str.count = 0;
                            break it;
                        }

                      case .ENTER; #through;
                      case .ESCAPE;
                        last_search_query_key_pressed = .ESCAPE;
                        inputting_search_query = false;
                        break it;
                    }
                }
            }
        }

        if key_held_passed_threshold(search_query_key_pressed_on_frame, last_search_query_key_pressed, frame, .BACKSPACE) { backspace_search_query(*search_query); move_cursor_to_first_search_result(); }
    }

    if cursor.selected < 0 {
        cursor.selected = 0;
    } else if cursor.selected > cursor.positions.count - 1 {
        cursor.selected = max(0, cursor.positions.count - 1);
    }

    if cursor.selected == {
      case 0;
        if cursor.positions[0] < 0 {
            cursor.positions[0] = 0;
        } else if cursor.positions[0] > library.artists.count - 1 {
            cursor.positions[0] = max(0, library.artists.count - 1);
        }
      case 1;
        artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
        assert(artist_ptr != null);
        if cursor.positions[1] < 0 {
            cursor.positions[1] = 0;
        } else if cursor.positions[1] > artist_ptr.albums.count - 1 {
            cursor.positions[1] = max(0, artist_ptr.albums.count - 1);
        }
      case 2;
        artist_ptr := table_find_pointer(*library.artists, library.artist_names_sorted[cursor.positions[0]]);
        assert(artist_ptr != null);
        album_ptr := table_find_pointer(*artist_ptr.albums, artist_ptr.album_names_sorted_by_date[cursor.positions[1]]);
        if cursor.positions[2] < 0 {
            cursor.positions[2] = 0;
        } else if cursor.positions[2] > album_ptr.songs.count - 1 {
            cursor.positions[2] = max(0, album_ptr.songs.count - 1);
        }
    }

    /*************
    * draw frame *
    *************/

    {
        /*********************************************
        * determine the artists/albums/songs to show *
        *********************************************/

        display_columns: [3] struct {
            width           : s32;
            rectangle_width : s32;
            entries         : [] Display_Text;
        };

        if library.artists.count > 0 {
            display_columns[0].width = cast(s32)(1 / 3.0 * display_width);
            display_columns[1].width = cast(s32)(1 / 3.0 * display_width);
            display_columns[2].width = cast(s32)display_width - display_columns[0].width - display_columns[1].width;

            display_columns[0].rectangle_width = display_columns[0].width - 50;
            display_columns[1].rectangle_width = display_columns[1].width - 50;
            display_columns[2].rectangle_width = display_columns[2].width;

            selected_artist_index := cursor.positions[0];
            if library.artists.count > 0 {
                index_start := max(0, min(library.artists.count - items_in_page, selected_artist_index  - items_in_page/ 2 + 1));
                index_end   := min(index_start + items_in_page, library.artists.count) - 1;
                display_columns[0].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

                max_characters_in_column := display_columns[0].rectangle_width / fonts.regular.w_width - 2;

                for i: index_start..index_end {
                    display_text: Display_Text;
                    display_text.text = create_temp_display_string_of_max_length(library.artist_names_sorted[i], max_characters_in_column);
                    display_text.selected = selected_artist_index == i;
                    display_text.font = fonts.regular;
                    display_columns[0].entries[i-index_start] = display_text;
                }
            }

            selected_album_index := cursor.positions[1];
            selected_artist      := table_find_pointer(*library.artists, library.artist_names_sorted[selected_artist_index]);
            if selected_artist.albums.count > 0 {
                index_start := max(0, min(selected_artist.albums.count - items_in_page, selected_album_index - items_in_page/ 2 + 1));
                index_end   := min(index_start + items_in_page, selected_artist.albums.count) - 1;
                display_columns[1].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

                max_characters_in_column := display_columns[1].rectangle_width / fonts.regular.w_width - 2;

                for i: index_start..index_end {
                    display_text: Display_Text;

                    album := table_find_pointer(*selected_artist.albums, selected_artist.album_names_sorted_by_date[i]);
                    assert(album != null);
                    display_text.text = create_temp_display_string_of_max_length(tprint("(%) %", to_string(album.date), album.name), max_characters_in_column);

                    display_text.selected = selected_album_index == i;
                    display_text.font = fonts.regular;
                    display_columns[1].entries[i-index_start] = display_text;
                }
            }

            selected_song_index := cursor.positions[2];
            selected_album      := table_find_pointer(*selected_artist.albums, selected_artist.album_names_sorted_by_date[selected_album_index]);
            if selected_album.songs.count > 0 {
                index_start := max(0, min(selected_album.songs.count - items_in_page, selected_song_index - items_in_page / 2 + 1));
                index_end   := min(index_start + items_in_page, selected_album.songs.count) - 1;
                display_columns[2].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

                max_characters_in_column := display_columns[2].rectangle_width / fonts.regular.w_width - 2;

                for i: index_start..index_end {
                    song := selected_album.songs[i];

                    padded_track := left_pad(song.track, #char " ", 3);
                    duration_time_string := seconds_to_time_string(song.duration);
                    // the additional constant subtraction at the end is from:
                    // -    2 for the '. ' between the track and title
                    // -    3 for the 3 spaces added between track_and_title and duration
                    title := create_temp_display_string_of_max_length(song.name, max_characters_in_column - padded_track.count - duration_time_string.count - 5);

                    track_and_title := tprint("%. %", padded_track, title);
                    // subtract 3 here, again for the 3 spaces added between track_and_title and duration
                    duration := left_pad(duration_time_string, #char " ", max_characters_in_column - get_unicode_length(track_and_title) - 3);

                    _, song_in_queue := table_find(*queue.queued_URIs, song.uri);

                    display_text: Display_Text;
                    display_text.text     = tprint("%   %", track_and_title, duration);
                    display_text.selected = selected_song_index == i;
                    display_text.font     = ifx song_in_queue then fonts.bold else fonts.regular;
                    display_columns[2].entries[i-index_start] = display_text;
                }
            }
        }

        /******************
        * draw everything *
        ******************/

        {
            top := header_bottom;
            x := X_MARGIN_SIZE;
            for column_index: 0..display_columns.count - 1 {
                y := top;
                column_width    := display_columns[column_index].width;
                rectangle_width := display_columns[column_index].rectangle_width;

                for display_text: display_columns[column_index].entries {
                    if display_text.selected {
                        Simp.set_shader_for_color();
                        color := ifx cursor.selected == column_index then rgba(1,1,1,1) else rgba(0.5,0.5,0.5,1);
                        Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + rectangle_width, cast(float)y + display_text.font.character_height, color);

                        Simp.draw_text(display_text.font, x, y, display_text.text, rgba(0,0,0,1));
                    } else {
                        // text_width := Simp.prepare_text(font, display_text.text);
                        // Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
                        // if column_index == 2 { // @Debug: remove this once font width problem is better understood/definitely fixed
                        //     expected_text_width := display_text.text.count * font.w_width;
                        //     if expected_text_width != text_width {
                        //         print("\nexpected_text_width: %\n", expected_text_width);
                        //         print("actual text width  : %\n", text_width);
                        //     }
                        // }

                        Simp.draw_text(display_text.font, x, y, display_text.text, rgba(1,1,1,1));
                    }

                    y -= TEXT_PADDING_Y + display_text.font.character_height;
                }
                x += column_width;
            }
        }
    }

    if inputting_search_query {
        // TODO: need to ensure the x/y here won't overlap with anything else
        Simp.draw_text(fonts.regular, X_MARGIN_SIZE, Y_MARGIN_SIZE, tprint("Search: %", search_query.str), rgba(1,1,1,1));
    }

    return inputting_search_query;
}
