#scope_file

#import "Basic";
#import "Hash_Table";
#import "Math";
#import "String";
#import "Unicode";

#import "common";

MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";
Input :: #import "Input";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_search_query_key_pressed: Key;
search_query_key_pressed_on_frame: Table(Key, u64);

search_query: Search_Query;

inputting_search_query := false;

cursor: struct {
    position := 0;
};

log_data :: Log_Data.{"queue", false};

#scope_export

Data :: struct {
    songs       : [..] *Song;
    version     : u32;
    queued_URIs : Table(string, u32);
}

load :: (mpd_connection: *MPD.connection, library: Library_Data) -> *Data {

    context.logger_data = *log_data;

    queue := New(Data);
    initialize_search_query(*search_query);
    if !mpd_connection return queue;

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    if !status {
        log("Status is null, not loading queue");
        return queue;
    }
    mpd_queue_length := MPD.status_get_queue_length(status);
    queue.version = MPD.status_get_queue_version(status);
    MPD.status_free(status);

    // reserve the space but don't resize the array, in case we can't find a queue song in the library
    array_reserve(*queue.songs, mpd_queue_length);

    MPD.send_list_queue_meta(mpd_connection);
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            defer {
                MPD.entity_free(entity);
                entity = MPD.recv_entity(mpd_connection);
                handle_errors("Receiving entity");
            }

            mpd_song := MPD.entity_get_song(entity);
            uri := copy_temp_from_c_string(MPD.song_get_uri(mpd_song));
            song_ptr, found := table_find(*library.songs_by_uri, uri);
            if !found {
                log("Queue song URI not found in library: '%'", uri, flags=.WARNING);
                continue;
            }
            array_add(*queue.songs, song_ptr);

            queue_song_id := MPD.song_get_id(mpd_song);
            table_add(*queue.queued_URIs, song_ptr.uri, queue_song_id);
        }
    }

    return queue;
}

update :: (mpd_connection: *MPD.connection, library: Library_Data, queue: *Data) {

    context.logger_data = *log_data;

    if !mpd_connection return;

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    if !status {
        log("Status is null, not refreshing queue", flags=.ERROR);
        return;
    }
    defer MPD.status_free(status);

    old_version := queue.version;
    queue.version = MPD.status_get_queue_version(status);
    if queue.version == old_version return;

    mpd_queue_length := MPD.status_get_queue_length(status);

    array_reset(*queue.songs);
    array_reserve(*queue.songs, mpd_queue_length);
    table_reset(*queue.queued_URIs);

    MPD.send_list_queue_meta(mpd_connection);
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            defer {
                MPD.entity_free(entity);
                entity = MPD.recv_entity(mpd_connection);
                handle_errors("Receiving entity");
            }

            mpd_song := MPD.entity_get_song(entity);
            uri := copy_temp_from_c_string(MPD.song_get_uri(mpd_song));

            song_ptr, found := table_find(*library.songs_by_uri, uri);
            if !found {
                log("Queue song URI not found in library: '%'", uri, flags=.WARNING);
                continue;
            }
            array_add(*queue.songs, song_ptr);

            queue_song_id := MPD.song_get_id(mpd_song);
            table_add(*queue.queued_URIs, song_ptr.uri, queue_song_id);
        }
    }
}

event_loop :: (mpd_connection: *MPD.connection, library: Library_Data, queue: *Data, frame: u64, fonts: Fonts, display_width: s32, header_bottom: int) -> bool {

    context.logger_data = *log_data;

    items_in_page := (header_bottom - Y_MARGIN_SIZE) / (fonts.regular.character_height + TEXT_PADDING_Y);

    shift_selected_item_down :: () #expand {
        if cursor.position < `queue.songs.count - 1 {
            MPD.run_swap(`mpd_connection, cast(u32)cursor.position, cast(u32)cursor.position + 1);
            handle_errors("Moving song down in queue");
            update(`mpd_connection, `library, `queue);
            `cursor.position += 1;
        }
    }
    move_cursor_down :: () #expand {
        `cursor.position += 1;
    }

    shift_selected_item_up :: () #expand {
        if cursor.position > 0 {
            MPD.run_swap(mpd_connection, cast(u32)cursor.position, cast(u32)cursor.position - 1);
            handle_errors("Moving song up in queue");
            update(`mpd_connection, `library, `queue);
            `cursor.position -= 1;
        }
    }
    move_cursor_up :: () #expand {
        `cursor.position -= 1;
    }

    move_cursor_half_page_down :: () #expand {
        `cursor.position += items_in_page / 2;
    }
    move_cursor_half_page_up :: () #expand {
        `cursor.position -= items_in_page / 2;
    }

    remove_selected_song :: () #expand {
        if cursor.position >= 0 && cursor.position <= queue.songs.count {
            MPD.run_delete(mpd_connection, cast(u32)cursor.position);
            handle_errors("Removing song from queue");
            update(`mpd_connection, `library, `queue);
            update_status(get_current_song(`mpd_connection, `queue));
        }
    }

    play_selected_song :: () #expand {
        MPD.run_play_pos(mpd_connection, cast(u32)cursor.position);
        handle_errors("Playing queue song");
            update_status(get_current_song(`mpd_connection, `queue));
    }

    move_cursor_to_next_search_result :: () #expand {
        if search_query.str == "" return;

        for i: 0..(queue.songs.count - 1) {
            song_index := (i + cursor.position + 1) % queue.songs.count;
            song := queue.songs[song_index];
            match := true;
            for s: split(search_query.str, SPACE) {
                if s.count == 0 continue;
                if !contains_nocase(song.artist, s) && !contains_nocase(song.album, s) && !contains_nocase(song.name, s) {
                    match = false;
                    break;
                }
            }
            if match {
                `cursor.position = song_index;
                break;
            }
        }
    }
    move_cursor_to_prev_search_result :: () #expand {
        if search_query.str == "" return;

        for < i: (queue.songs.count - 1)..0 {
            song_index := (i + cursor.position) % queue.songs.count;
            song := queue.songs[song_index];
            match := true;
            for s: split(search_query.str, SPACE) {
                if s.count == 0 continue;
                if !contains_nocase(song.artist, s) && !contains_nocase(song.album, s) && !contains_nocase(song.name, s) {
                    match = false;
                    break;
                }
            }
            if match {
                `cursor.position = song_index;
                break;
            }
        }
    }

    if !inputting_search_query {
        for Input.events_this_frame {
            if it.type == {
              case .KEYBOARD;
                if it.key_pressed {
                    if it.ctrl_pressed {
                        if it.key_code == {

                          case KEY_D;
                            table_set(*key_pressed_on_frame, .CTRL_D, frame);
                            last_key_pressed = .CTRL_D;
                            move_cursor_half_page_down();
                            break it;
                          case KEY_U;
                            table_set(*key_pressed_on_frame, .CTRL_U, frame);
                            last_key_pressed = .CTRL_U;
                            move_cursor_half_page_up();
                            break it;

                        }
                    } else {
                        if it.key_code == {

                          case KEY_J;
                            if it.shift_pressed {
                                table_set(*key_pressed_on_frame, .SHIFT_J, frame);
                                last_key_pressed = .SHIFT_J;
                                shift_selected_item_down();
                            } else {
                                table_set(*key_pressed_on_frame, .J, frame);
                                last_key_pressed = .J;
                                move_cursor_down();
                            }
                            break it;
                          case KEY_K;
                            if it.shift_pressed {
                                table_set(*key_pressed_on_frame, .SHIFT_K, frame);
                                last_key_pressed = .SHIFT_K;
                                shift_selected_item_up();
                            } else {
                                table_set(*key_pressed_on_frame, .K, frame);
                                last_key_pressed = .K;
                                move_cursor_up();
                            }
                            break it;

                          case KEY_G;
                            if it.shift_pressed {
                                cursor.position = queue.songs.count - 1;
                            } else {
                                cursor.position = 0;
                            }
                            break it;

                          case KEY_X;
                            table_set(*key_pressed_on_frame, .X, frame);
                            last_key_pressed = .X;
                            remove_selected_song();
                            break it;

                          case KEY_O; // move cursor to currently playing song
                            mpd_current_song := MPD.run_current_song(mpd_connection);
                            handle_errors("Getting current song");
                            if !mpd_current_song break;
                            uri := to_string(MPD.song_get_uri(mpd_current_song));

                            for song: queue.songs {
                                if song.uri == uri {
                                    cursor.position = it_index;
                                }
                            }
                            break it;

                          case .ENTER; // play selected song
                            table_set(*key_pressed_on_frame, .ENTER, frame);
                            last_key_pressed = .ENTER;
                            play_selected_song();
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
        }

        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       move_cursor_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       move_cursor_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_J) shift_selected_item_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_K) shift_selected_item_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  move_cursor_half_page_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  move_cursor_half_page_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .X)       remove_selected_song();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .N)       move_cursor_to_next_search_result();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_N) move_cursor_to_prev_search_result();
    } else {

        /*****************************
        * user entering search query *
        *****************************/

        move_cursor_to_first_search_result :: () #expand {
            if search_query.str == "" return;

            for song, song_index: queue.songs  {
                song := queue.songs[song_index];
                match := true;
                for s: split(search_query.str, SPACE) {
                    if s.count == 0 continue;
                    if !contains_nocase(song.artist, s) && !contains_nocase(song.album, s) && !contains_nocase(song.name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.position = song_index;
                    break;
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

    if cursor.position < 0 {
        cursor.position = 0;
    } else if cursor.position > queue.songs.count - 1 {
        cursor.position = queue.songs.count - 1;
    }

    /*************
    * draw frame *
    *************/

    // draw_frame :: (items_in_page: int, header_bottom: int) {
    {
        display_columns: [4] struct {
            width           : s32;
            entries         : [] Display_Text;
        };

        {
            index_start := max(0, min(queue.songs.count - items_in_page, cursor.position - items_in_page/ 2 + 1));
            index_end   := min(index_start + items_in_page, queue.songs.count) - 1;

            display_columns[0].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);
            display_columns[1].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);
            display_columns[2].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);
            display_columns[3].entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

            display_columns[0].width = cast(s32)(8 / 20.0 * display_width);
            display_columns[1].width = cast(s32)(5 / 20.0 * display_width);
            display_columns[2].width = cast(s32)(5 / 20.0 * display_width);
            display_columns[3].width = display_width - display_columns[0].width - display_columns[1].width - display_columns[2].width;

            selected_index := cursor.position;

            for i: index_start..index_end {
                entry := i - index_start;
                song := queue.songs[i];
                selected := i == selected_index;
                font := ifx i == status.queue_position then fonts.bold else fonts.regular;

                { // song name
                    max_characters_in_column := display_columns[0].width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.text = create_temp_display_string_of_max_length(song.name, max_characters_in_column);
                    display_text.selected = selected;
                    display_text.font = font;
                    display_columns[0].entries[entry] = display_text;
                }

                { // album name
                    max_characters_in_column := display_columns[1].width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.selected = selected;
                    display_text.text = create_temp_display_string_of_max_length(song.album, max_characters_in_column);
                    display_text.font = font;
                    display_columns[1].entries[entry] = display_text;
                }

                { // artist name
                    max_characters_in_column := display_columns[2].width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.selected = selected;
                    display_text.text = create_temp_display_string_of_max_length(song.artist, max_characters_in_column);
                    display_text.font = font;
                    display_columns[2].entries[entry] = display_text;
                }

                { // song duration
                    max_characters_in_column := display_columns[3].width / font.w_width - 2;
                    duration_time_string := left_pad(seconds_to_time_string(song.duration), #char " ", max_characters_in_column);
                    display_text: Display_Text;
                    display_text.selected = selected;
                    display_text.text = create_temp_display_string_of_max_length(duration_time_string, max_characters_in_column);
                    display_text.font = font;
                    display_columns[3].entries[entry] = display_text;
                }
            }
        }

        {
            top := header_bottom;
            x := X_MARGIN_SIZE;
            for column_index: 0..(display_columns.count - 1) {
                y := top;
                column_width := display_columns[column_index].width;

                for display_text: display_columns[column_index].entries {
                    if display_text.selected {
                        Simp.set_shader_for_color();
                        color := ifx column_index == 0 then rgba(1,1,1,1) else rgba(0.5, 0.5, 0.5, 1); // highlight the first column (song title) brighter than the rest
                        Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width, cast(float)y + display_text.font.character_height, color);
                        Simp.draw_text(display_text.font, x, y, display_text.text, rgba(0,0,0,1));
                    } else {
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

get_current_song :: (mpd_connection: *MPD.connection, queue: Data) -> *Song {

    if !mpd_connection return null;

    context.logger_data = *log_data;

    mpd_status := MPD.run_status(mpd_connection);
    handle_errors("Retrieving MPD status");
    MPD.response_finish(mpd_connection);
    if !mpd_status return null;
    defer MPD.status_free(mpd_status);

    queue_song_position := MPD.status_get_song_pos(mpd_status);
    if queue_song_position < 0 return null;
    assert(queue_song_position < queue.songs.count, "Queue song position was %, should be less than %", queue_song_position, queue.songs.count);
    return queue.songs[queue_song_position];
}
