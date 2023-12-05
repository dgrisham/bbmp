#import "Basic";
#import "Hash_Table";
#import "Math";
#import "String";

#import "common";

MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";
Input :: #import "Input";

Queue :: #import "queue";

Data :: struct {
    playlists             : Table(string, Playlist);
    playlist_names_sorted : [..] string;
}

Playlist :: struct {
    name              : string;
    song_URIs         : [..] string;
    // cover_path        : string;
    // thumbnail_texture : *Simp.Texture;
    // thumbnail_bitmap  : *Simp.Bitmap;
    // mutex             : Mutex;
}

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_search_query_key_pressed: Key;
search_query_key_pressed_on_frame: Table(Key, u64);

search_query: Search_Query;

inputting_search_query := false;

cursor: struct {
    positions := int.[0, 0];
    selected  := 0;
};

log_data :: Log_Data.{"playlist", false};

#scope_export

load :: (library: Library_Data) -> Data {

    initialize_search_query(*search_query);

    playlist_data: Data;

    if !mpd_connection return playlist_data;

    playlist_paths: [..] *u8;

    if MPD.send_list_playlists(mpd_connection) {
        mpd_playlist := MPD.recv_playlist(mpd_connection);
        handle_errors("Receiving playlist");
        while mpd_playlist {
            mpd_playlist_path := MPD.playlist_get_path(mpd_playlist);
            if mpd_playlist_path {
                array_add(*playlist_paths, mpd_playlist_path);
            }
            mpd_playlist = MPD.recv_playlist(mpd_connection);
            handle_errors("Receiving playlist");
        }
    } else {
        handle_errors("Listing playlists");
    }

    array_reserve(*playlist_data.playlist_names_sorted, playlist_paths.count);
    for playlist_path: playlist_paths {
        if MPD.send_list_playlist(mpd_connection, playlist_path) {
            entity := MPD.recv_entity(mpd_connection);
            handle_errors(tprint("Receiving first entity for playlist '%'", copy_temp_from_c_string(playlist_path)));
            if !entity continue;

            playlist: Playlist;
            playlist.name = copy_from_c_string(playlist_path);
            while entity {
                if MPD.entity_get_type(entity) == .SONG {
                    mpd_song := MPD.entity_get_song(entity);
                    array_add(*playlist.song_URIs, copy_from_c_string(MPD.song_get_uri(mpd_song)));
                }

                MPD.entity_free(entity);
                entity = MPD.recv_entity(mpd_connection);
                handle_errors(tprint("Receiving entity for playlist '%'", playlist.name));
            }
            table_set(*playlist_data.playlists, playlist.name, playlist);

            index := 0;
            for playlist_data.playlist_names_sorted {
                if compare_nocase(playlist.name, it) < 0 break;
                index += 1;
            }
            array_insert_at(*playlist_data.playlist_names_sorted, playlist.name, index);
        } else {
            handle_errors(tprint("Listing playlist '%'", playlist_path));
        }
    }
    array_free(playlist_paths);

    return playlist_data;
}

event_loop :: (mpd_connection: *MPD.connection, using playlist_data: Data, library: Library_Data, queue: *Queue.Data, frame: u64, fonts: Fonts, display_width: s32, header_bottom: int) -> bool {
    context.logger_data = *log_data;

    max_items_in_page := (header_bottom - Y_MARGIN_SIZE) / (fonts.regular.character_height + TEXT_PADDING_Y);

    move_selected_cursor :: (amount: int) #expand {
        `cursor.positions[cursor.selected] += amount;
        if cursor.selected == 0 `cursor.positions[1] = 0;
    }
    move_selected_cursor_up             :: () #expand { move_selected_cursor(-1);                 }
    move_selected_cursor_down           :: () #expand { move_selected_cursor(+1);                 }
    move_selected_cursor_half_page_up   :: () #expand { move_selected_cursor(-max_items_in_page / 2); }
    move_selected_cursor_half_page_down :: () #expand { move_selected_cursor(+max_items_in_page / 2); }

    move_selected_cursor_left  :: () #expand { `cursor.selected -= 1; }
    move_selected_cursor_right :: () #expand { `cursor.selected += 1; }

    add_selection_to_queue_and_increment_cursor :: () -> s32 #expand {
        if !mpd_connection {
            log("No connection to MPD, cannot add song to queue", flags=.ERROR);
            return -1;
        }

        playlist_name := `playlist_names_sorted[cursor.positions[0]];
        playlist, found := table_find(*`playlists, playlist_name);
        assert(found, "Failed to find playlist '%'", playlist_name);

        if cursor.selected == {
          case 0;
            add_playlist_to_queue(playlist);
          case 1;
            song_uri := playlist.song_URIs[cursor.positions[1]];
            ids := table_find_multiple(*queue.queued_URIs, song_uri);
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

        playlist_name := playlist_names_sorted[cursor.positions[0]];
        playlist, success := table_find(*`playlists, playlist_name);
        assert(success, "Failed to find playlist '%'", playlist_name);

        first_song_id_added: s32;
        if cursor.selected == {
          case 0;
            first_song_id_added = add_playlist_to_queue(playlist);
          case 1;
            first_song_id_added = MPD.run_add_id(mpd_connection, temp_c_string(playlist.song_URIs[cursor.positions[1]]));
        }

        if first_song_id_added >= 0 {
            MPD.run_play_id(mpd_connection, cast(u32)first_song_id_added);
            handle_errors("Playing first song in group added to queue");
            Queue.update(`mpd_connection, library, `queue);
            update_status(Queue.get_current_song(`mpd_connection, `queue));
        }
    }

    add_playlist_to_queue :: (playlist: Playlist) -> s32 #expand {
        first_id_added: s32;
        for song_uri, song_index: playlist.song_URIs {
            id := MPD.run_add_id(mpd_connection, temp_c_string(song_uri));
            handle_errors(tprint("Adding song with URI '%' from playlist '%' to queue", song_uri, playlist.name));
            if id > 0 && song_index == 0 {
                first_id_added = id;
            }
        }
        return first_id_added;
    }

    move_cursor_to_next_search_result :: () #expand {
        if search_query.str == "" return;

        if cursor.selected == {
          case 0;
            for i: 0..(`playlist_names_sorted.count - 1) {
                playlist_index := (i + cursor.positions[0] + 1) % `playlist_names_sorted.count;
                playlist_name := `playlist_names_sorted[playlist_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(playlist_name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[0] = playlist_index;
                    `cursor.positions[1] = 0;
                    break;
                }
            }
          case 1;
            playlist_name := `playlist_names_sorted[cursor.positions[0]];
            playlist, found := table_find(*`playlists, playlist_name);
            assert(found, "Expected to find playlist during playlist song search query");
            for i: 0..(playlist.song_URIs.count - 1) {
                song_index := (i + cursor.positions[1] + 1) % playlist.song_URIs.count;
                song_uri := playlist.song_URIs[song_index];
                song, found := table_find(*library.songs_by_uri, song_uri);

                match := true;
                if !found { // song not found in library, just search the URI string
                    if !contains_nocase(song_uri, search_query.str) {
                        match = false;
                    }
                } else {
                    for s: split(search_query.str, SPACE) {
                        if s.count == 0 continue;
                        if !contains_nocase(song.artist, s) && !contains_nocase(song.album, s) && !contains_nocase(song.name, s) {
                            match = false;
                            break;
                        }
                    }
                }

                if match {
                    `cursor.positions[1] = song_index;
                    break;
                }
            }
        }
    }
    move_cursor_to_prev_search_result :: () #expand {
        if search_query.str == "" return;

        if cursor.selected == {
          case 0;
            for < i: (playlist_names_sorted.count - 1)..0 {
                playlist_index := (i + cursor.positions[0]) % playlist_names_sorted.count;
                playlist_name  := playlist_names_sorted[playlist_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if !contains_nocase(playlist_name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.positions[0] = playlist_index;
                    `cursor.positions[1] = 0;
                    break;
                }
            }
          case 1;
            playlist_name := playlist_names_sorted[cursor.positions[0]];
            playlist, found := table_find(*playlists, playlist_name);
            assert(found, "Expected to find playlist during playlist song search query");
            for < i: (playlist.song_URIs.count - 1)..0 {
                song_index := (i + cursor.positions[1] + 1) % playlist.song_URIs.count;
                song_uri := playlist.song_URIs[song_index];
                song, found := table_find(*library.songs_by_uri, song_uri);

                match := true;
                if !found { // song not found in library, just search the URI string
                    if !contains_nocase(song_uri, search_query.str) {
                        match = false;
                    }
                } else {
                    for s: split(search_query.str, SPACE) {
                        if s.count == 0 continue;
                        if !contains_nocase(song.artist, s) && !contains_nocase(song.album, s) && !contains_nocase(song.name, s) {
                            match = false;
                            break;
                        }
                    }
                }

                if match {
                    `cursor.positions[1] = song_index;
                    break;
                }
            }
        }
    }

    if !inputting_search_query {
        for Input.events_this_frame {
            if it.type == .KEYBOARD && it.key_pressed {
                if it.ctrl_pressed {
                    if it.key_code == {

                      case KEY_D;
                        last_key_pressed = .CTRL_D;
                        table_set(*key_pressed_on_frame, .CTRL_D, frame);
                        move_selected_cursor_half_page_down();
                        break it;
                      case KEY_U;
                        last_key_pressed = .CTRL_U;
                        table_set(*key_pressed_on_frame, .CTRL_U, frame);
                        move_selected_cursor_half_page_up();
                        break it;

                    }
                } else {
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

                      case KEY_G;
                        if cursor.selected == {
                            case 0;
                              if it.shift_pressed {
                                  cursor.positions[0] = max(0, playlists.count - 1);
                              } else {
                                  cursor.positions[0] = 0;
                              }
                              cursor.positions[1] = 0;
                            case 1;
                              if it.shift_pressed {
                                  playlist, success := table_find(*playlists, playlist_names_sorted[cursor.positions[0]]);
                                  assert(success);
                                  cursor.positions[1] = max(0, playlist.song_URIs.count - 1);
                              } else {
                                cursor.positions[1] = 0;
                              }
                        }
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
                for playlist_name, playlist_index: playlist_names_sorted {
                    match := true;
                    for s: split(search_query.str, SPACE) {
                        if !contains_nocase(playlist_name, s) {
                            match = false;
                            break;
                        }
                    }
                    if match {
                        `cursor.positions[0] = playlist_index;
                        `cursor.positions[1] = 0;
                        break;
                    }
                }
              case 1;
                playlist, found := table_find(*playlists, playlist_names_sorted[cursor.positions[0]]);
                assert(found);
                for song_uri, song_index: playlist.song_URIs {
                    song, found := table_find(*library.songs_by_uri, song_uri);

                    match := true;
                    if !found { // song not found in library, just search the URI string
                        if !contains_nocase(song_uri, search_query.str) {
                            match = false;
                        }
                    } else {
                        for s: split(search_query.str, SPACE) {
                            if s.count == 0 continue;
                            if !contains_nocase(song.artist, s) && !contains_nocase(song.album, s) && !contains_nocase(song.name, s) {
                                match = false;
                                break;
                            }
                        }
                    }

                    if match {
                        `cursor.positions[1] = song_index;
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
        } else if cursor.positions[0] > playlists.count - 1 {
            cursor.positions[0] = max(0, playlists.count - 1);
        }
      case 1;
        playlist := table_find_pointer(*playlists, playlist_names_sorted[cursor.positions[0]]);
        assert(playlist != null);
        if cursor.positions[1] < 0 {
            cursor.positions[1] = 0;
        } else if cursor.positions[1] > playlist.song_URIs.count - 1 {
            cursor.positions[1] = max(0, playlist.song_URIs.count - 1);
        }
    }

    /*************
    * draw frame *
    *************/

    {
        /********************************************
        * determine the playlists and songs to show *
        ********************************************/

        display_columns: [2] struct {
            width           : s32;
            rectangle_width : s32;
            entries         : [] Display_Text;
        };

        Display_Text :: struct {
            text     : string;
            selected : bool;
            font     : *Simp.Dynamic_Font;
            color    : Vector4;
        }

        if playlists.count > 0 {
            display_columns[0].width = cast(s32)(1 / 3.0 * display_width);
            display_columns[1].width = cast(s32)display_width - display_columns[0].width;

            display_columns[0].rectangle_width = display_columns[0].width - 50;
            display_columns[1].rectangle_width = display_columns[1].width;

            selected_playlist_index := cursor.positions[0];
            if playlists.count > 0 {
                index_start := max(0, min(playlists.count - max_items_in_page, selected_playlist_index - max_items_in_page/ 2 + 1));
                index_end   := min(index_start + max_items_in_page, playlists.count) - 1;
                display_columns[0].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

                max_characters_in_column := display_columns[0].rectangle_width / fonts.regular.w_width - 2;

                for i: index_start..index_end {
                    display_text: Display_Text;
                    display_text.text = create_temp_display_string_of_max_length(playlist_names_sorted[i], max_characters_in_column);
                    display_text.selected = selected_playlist_index == i;
                    display_text.color = .{1,1,1,1};
                    display_text.font  = fonts.regular;
                    display_columns[0].entries[i-index_start] = display_text;
                }
            }

            selected_song_index := cursor.positions[1];
            selected_playlist   := table_find_pointer(*playlists, playlist_names_sorted[selected_playlist_index]);
            if selected_playlist.song_URIs.count > 0 {
                index_start := max(0, min(selected_playlist.song_URIs.count - max_items_in_page, selected_song_index - max_items_in_page/ 2 + 1));
                index_end   := min(index_start + max_items_in_page, selected_playlist.song_URIs.count) - 1;
                display_columns[1].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

                max_characters_in_column := display_columns[1].rectangle_width / fonts.regular.w_width - 2;

                display_text: Display_Text;
                for i: index_start..index_end {
                    song_name: string;
                    duration_time_string: string;
                    {
                        song_uri := selected_playlist.song_URIs[i];
                        song, success := table_find(*library.songs_by_uri, song_uri);
                        if success {
                            song_name = song.name;
                            duration_time_string = seconds_to_time_string(song.duration);
                            display_text.color = rgba(1,1,1,1);

                            _, song_in_queue := table_find(*queue.queued_URIs, song_uri);
                            display_text.font = ifx song_in_queue then fonts.bold else fonts.regular;
                        } else {
                            song_name = song_uri;
                            duration_time_string = "-:--";
                            display_text.color = rgba(1,0,0,1);
                            display_text.font  = fonts.regular;
                        }
                    }

                    padded_track := left_pad(i+1, #char " ", 3);
                    // the additional constant subtraction at the end is from:
                    // -    2 for the '. ' between the track and title
                    // -    3 for the 3 spaces added between track_and_title and duration
                    title := create_temp_display_string_of_max_length(song_name, max_characters_in_column - padded_track.count - duration_time_string.count - 5);

                    track_and_title := tprint("%. %", padded_track, title);
                    // subtract 3 here, again for the 3 spaces added between track_and_title and duration
                    duration := left_pad(duration_time_string, #char " ", max_characters_in_column - get_unicode_length(track_and_title) - 3);

                    display_text.text     = tprint("%   %", track_and_title, duration);
                    display_text.selected = selected_song_index == i;
                    display_columns[1].entries[i-index_start] = display_text;
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
                        color := ifx cursor.selected == column_index then display_text.color else rgba(0.5,0.5,0.5,1);
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

                        Simp.draw_text(display_text.font, x, y, display_text.text, display_text.color);
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
