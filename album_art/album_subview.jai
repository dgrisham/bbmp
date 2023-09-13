#scope_file

#import "common";

Input :: #import "Input";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_search_query_key_pressed: Key;
search_query_key_pressed_on_frame: Table(Key, u64);

search_query: Search_Query;

inputting_search_query := false;

log_data :: Log_Data.{"album_art/album", false};

#scope_module

album_search_query :: *search_query;

process_album_input :: (mpd_connection: *MPD.connection, library: Library_Data, queue: *Queue.Data, albums: [] *Album, frame: u64, header_bottom: int, items_in_page: int, album: *Album) -> bool {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    move_cursor_by_n_songs :: (number_of_songs_in_album: int, amount: int) #expand {
        `cursor.song_position += amount;
        if `cursor.song_position < 0 {
            `cursor.song_position = 0;
        } else if `cursor.song_position > number_of_songs_in_album - 1 {
            `cursor.song_position = number_of_songs_in_album - 1;
        }
    }
    move_cursor_to_prev_song  :: () #expand { move_cursor_by_n_songs(`album.songs.count,             -1); }
    move_cursor_to_next_song  :: () #expand { move_cursor_by_n_songs(`album.songs.count,             +1); }
    move_cursor_one_page_up   :: () #expand { move_cursor_by_n_songs(`album.songs.count, -items_in_page); }
    move_cursor_one_page_down :: () #expand { move_cursor_by_n_songs(`album.songs.count, +items_in_page); }

    move_cursor_to_next_album_and_reset_song_position :: () #expand {
        move_cursor_to_next_album();
        `cursor.song_position = 0;
    }
    move_cursor_to_prev_album_and_reset_song_position :: () #expand {
        move_cursor_to_prev_album();
        `cursor.song_position = 0;
    }

    add_selected_song_to_queue_and_play :: () #expand {
        if !mpd_connection {
            log("No connection to MPD, cannot add song to queue", flags=.ERROR);
            return;
        }

        song_uri := `album.songs[`cursor.song_position].uri;
        id := MPD.run_add_id(mpd_connection, to_c_string(song_uri));
        handle_errors(tprint("Adding song to queue from album view, URI '%'", song_uri));
        if id > 0 {
            MPD.run_play_id(mpd_connection, cast(u32)id);
            handle_errors("Playing song added to queue");
        }

        Queue.update(`mpd_connection, `library, `queue);
        update_status(Queue.get_current_song(`mpd_connection, `queue));
    }

    toggle_selected_song_in_queue_and_increment_cursor :: () #expand {
        if !mpd_connection {
            log("No connection to MPD, cannot add song to queue", flags=.ERROR);
            return;
        }

        ids := table_find_multiple(*queue.queued_URIs, `album.songs[`cursor.song_position].uri);
        if ids.count {
            for id: ids {
                MPD.run_delete_id(mpd_connection, id);
                handle_errors("Deleting song from queue");
            }
        } else {
            MPD.run_add_id(mpd_connection, to_c_string(`album.songs[`cursor.song_position].uri));
            handle_errors("Adding song to queue");
        }

        Queue.update(`mpd_connection, `library, `queue);
        update_status(Queue.get_current_song(`mpd_connection, `queue));

        move_cursor_to_next_song();
    }

    move_cursor_to_next_search_result :: () #expand {
        if search_query.str == "" return;

        for i: 0..(`album.songs.count - 1) {
            song_index := (i + cursor.song_position + 1) % `album.songs.count;
            song := `album.songs[song_index];
            match := true;
            for s: split(search_query.str, SPACE) {
                if s.count == 0 continue;
                if !contains_nocase(song.name, s) {
                    match = false;
                    break;
                }
            }
            if match {
                `cursor.song_position = song_index;
                break;
            }
        }
    }
    move_cursor_to_prev_search_result :: () #expand {
        if search_query.str == "" return;

        for < i: (`album.songs.count - 1)..0 {
            song_index := (i + cursor.song_position) % `album.songs.count;
            song := `album.songs[song_index];
            match := true;
            for s: split(search_query.str, SPACE) {
                if s.count == 0 continue;
                if !contains_nocase(song.name, s) {
                    match = false;
                    break;
                }
            }
            if match {
                `cursor.song_position = song_index;
                break;
            }
        }
    }

    if !inputting_search_query {
        for Input.events_this_frame {
            if it.type == {
              case .KEYBOARD;
                if it.key_pressed {
                    if it.key_code == {

                      case KEY_I;
                        current_album_art_subview = .LIBRARY;
                        cursor.song_position = 0;
                        break it;

                      case KEY_J;
                        table_set(*key_pressed_on_frame, .J, frame);
                        last_key_pressed = .J;
                        move_cursor_to_next_song();
                        break it;
                      case KEY_K;
                        table_set(*key_pressed_on_frame, .K, frame);
                        last_key_pressed = .K;
                        move_cursor_to_prev_song();
                        break it;

                      case KEY_H;
                        table_set(*key_pressed_on_frame, .H, frame);
                        last_key_pressed = .H;
                        move_cursor_to_prev_album_and_reset_song_position();
                        break it;
                      case KEY_L;
                        table_set(*key_pressed_on_frame, .L, frame);
                        last_key_pressed = .L;
                        move_cursor_to_next_album_and_reset_song_position();
                        break it;

                      case KEY_D;
                        if it.ctrl_pressed {
                            table_set(*key_pressed_on_frame, .CTRL_D, frame);
                            last_key_pressed = .CTRL_D;
                            move_cursor_one_page_down();
                        }
                        break it;
                      case KEY_U;
                        if it.ctrl_pressed {
                            table_set(*key_pressed_on_frame, .CTRL_U, frame);
                            last_key_pressed = .CTRL_U;
                            move_cursor_one_page_up();
                        }
                        break it;

                      case KEY_G;
                        if it.shift_pressed {
                            cursor.song_position = album.songs.count - 1;
                        } else {
                            cursor.song_position = 0;
                        }
                        break it;

                      case KEY_O;
                        mpd_current_song := MPD.run_current_song(mpd_connection);
                        handle_errors("Getting current song");
                        if !mpd_current_song break;
                        uri := to_string(MPD.song_get_uri(mpd_current_song));
                        for album, album_index: albums {
                            for song, song_index: album.songs {
                                if song.uri == uri {
                                    // @Cleanup This is the first time we're updating cursor for another 'view'.
                                    cursor.album_position = album_index;
                                    cursor.song_position  = song_index;
                                    break;
                                }
                            }
                        }
                        break it;

                      case .SPACEBAR;
                        table_set(*key_pressed_on_frame, .SPACE, frame);
                        last_key_pressed = .SPACE;
                        toggle_selected_song_in_queue_and_increment_cursor();
                        break it;

                      case .ENTER;
                        table_set(*key_pressed_on_frame, .ENTER, frame);
                        last_key_pressed = .ENTER;
                        add_selected_song_to_queue_and_play();
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

        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       move_cursor_to_next_song();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       move_cursor_to_prev_song();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .H)       move_cursor_to_prev_album_and_reset_song_position();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .L)       move_cursor_to_next_album_and_reset_song_position();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  move_cursor_one_page_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  move_cursor_one_page_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SPACE)   toggle_selected_song_in_queue_and_increment_cursor();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .ENTER)   add_selected_song_to_queue_and_play();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .N)       move_cursor_to_next_search_result();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_N) move_cursor_to_prev_search_result();
    } else {

        /*****************************
        * user entering search query *
        *****************************/

        move_cursor_to_first_search_result :: () #expand {
            if search_query.str == "" return;

            for song, song_index: album.songs {
                match := true;
                for s: split(search_query.str, SPACE) {
                    if s.count == 0 continue;
                    if !contains_nocase(song.name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.song_position = song_index;
                    break;
                }
            }
        }

        for Input.events_this_frame {
            if it.type == {

              case .TEXT_INPUT;
                if append_utf32_to_search_query(*search_query, it.utf32) move_cursor_to_first_search_result();
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

    return inputting_search_query;
}

loaded_album: struct {
    artist_name : string;
    album_name  : string;
    art_texture : *Simp.Texture;
    art_loaded  : bool = false;
}

draw_album_frame :: (album: *Album, queue: Queue.Data, load_current_album_art: bool, fonts: Fonts, total_width: s32, header_bottom: int, items_in_page: int) {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    if loaded_album.art_texture == null loaded_album.art_texture = New(Simp.Texture); // initialize loaded art texture, should only happen on the first album view frame

    if album.artist_name != loaded_album.artist_name || album.name != loaded_album.album_name { // album changed, reset loaded album
        free(loaded_album.artist_name);
        free(loaded_album.album_name);
        loaded_album.artist_name    = copy_string(album.artist_name);
        loaded_album.album_name     = copy_string(album.name);
        loaded_album.art_loaded     = false;

        load_current_album_art = true;
    }

    if load_current_album_art { // load thumbnail from disk
        if album.cover_path != "" {
            display_art_path := tprint("%/%-%x.bmp", config.album_cover_directory, get_hash(tprint("%-%", album.artist_name, album.name)), LARGE_ALBUM_ART_WIDTH);
            if file_exists(display_art_path) {
                start := current_time();
                if !Simp.texture_load_from_file(loaded_album.art_texture, display_art_path) {
                    log("Failed to load display art for % - %", album.artist_name, album.name, flags=.ERROR);
                } else {
                    log("display album art load time: % ms", (current_time() - start) / 1000.0, flags=.VERBOSE_ONLY);
                    loaded_album.art_loaded = true;
                }
            }
        }
    }

    /***********************
    * draw the album cover *
    ***********************/

    cover_display_width  := cast(float)ALBUM_ART_DISPLAY_WIDTH;
    cover_display_height := cover_display_width;

    cover_x := cast(float)X_MARGIN_SIZE;
    cover_y := cast(float)(header_bottom - Y_MARGIN_SIZE - cover_display_height) / 2;
    if loaded_album.art_loaded {
        cover_display_height = cover_display_width * cast(float)loaded_album.art_texture.height / loaded_album.art_texture.width;
        remaining_height := cast(float)(header_bottom - Y_MARGIN_SIZE);
        if cover_display_height > remaining_height {
            cover_display_height = remaining_height;
            cover_display_width = cover_display_height * cast(float)loaded_album.art_texture.width / loaded_album.art_texture.height;
        }
        cover_y = cast(float)(header_bottom - cover_display_height) * 5 / 8;

        Simp.set_shader_for_images(loaded_album.art_texture);
        Simp.immediate_begin();

        Simp.immediate_quad(
            xy(cover_x                      , cover_y),
            xy(cover_x + cover_display_width, cover_y),
            xy(cover_x + cover_display_width, cover_y + cover_display_height),
            xy(cover_x                      , cover_y + cover_display_height),
        );

        Simp.immediate_flush();
    }

    /**********************************************************
    * determine the list of songs + positions to draw them in *
    **********************************************************/

    text_x := cast(s64)(cover_x + cover_display_width + X_MARGIN_SIZE);

    rectangle_width := total_width - X_MARGIN_SIZE - text_x;
    max_characters_in_column := rectangle_width / fonts.regular.w_width - 2;

    display_entries: []Display_Text;
    selected_song_index := cursor.song_position;
    {
        index_start := max(0, min(album.songs.count - items_in_page, selected_song_index - items_in_page / 2 + 1));
        index_end   := min(index_start + items_in_page, album.songs.count) - 1;
        display_entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

        for i: index_start..index_end {
            song := album.songs[i];

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
            display_text.text = tprint("%   %", track_and_title, duration);
            display_text.selected = selected_song_index == i;
            display_text.font     = ifx song_in_queue then fonts.bold else fonts.regular;
            display_entries[i-index_start] = display_text;
        }
    }

    /*************************************************
    * draw the album metadata header + list of songs *
    *************************************************/

    text_y := min(
        // this roughly vertically centers the song list with the album cover
        cast(s64)(
            cover_y + cover_display_height * 1 / 2                                                              // album cover center
            + Y_MARGIN_SIZE                                                                                     // gap between album metadata and tracklist
            + (3 + (display_entries.count - 1) / 2.0) * (fonts.regular.character_height + TEXT_PADDING_Y) - 2 * TEXT_PADDING_Y // total height of text that we draw (the subtraction at the end is to adjust from double counting)
        ),
        // height limit based on the remaining screen size
        header_bottom - Y_MARGIN_SIZE,
    );

    x_center := (total_width - X_MARGIN_SIZE + text_x) / 2;
    {
        width := Simp.prepare_text(fonts.regular, album.name);
        Simp.draw_prepared_text(fonts.regular, x_center - width / 2, text_y, rgba(1,1,1,1));
    }
    text_y -= TEXT_PADDING_Y + fonts.regular.character_height;

    {
        width := Simp.prepare_text(fonts.regular, album.artist_name);
        Simp.draw_prepared_text(fonts.regular, x_center - width / 2, text_y, rgba(1,1,1,1));
    }
    text_y -= TEXT_PADDING_Y + fonts.regular.character_height;

    {
        width := Simp.prepare_text(fonts.regular, to_long_date_string(album.date));
        Simp.draw_prepared_text(fonts.regular, x_center - width / 2, text_y, rgba(1,1,1,1));
    }
    text_y -= fonts.regular.character_height;

    text_y -= Y_MARGIN_SIZE;

    for display_text: display_entries {
        if display_text.selected {
            Simp.set_shader_for_color();
            Simp.immediate_quad(cast(float)text_x - 10, cast(float)text_y - 5, cast(float)text_x + rectangle_width, cast(float)text_y + display_text.font.character_height, rgba(1,1,1,1));
            Simp.draw_text(display_text.font, text_x, text_y, display_text.text, rgba(0,0,0,1));
        } else {
            Simp.draw_text(display_text.font, text_x, text_y, display_text.text, rgba(1,1,1,1));
        }
        text_y -= TEXT_PADDING_Y + display_text.font.character_height;
    }

    if inputting_search_query {
        // TODO: need to ensure the x/y here won't overlap with anything else
        Simp.draw_text(fonts.regular, X_MARGIN_SIZE, Y_MARGIN_SIZE, tprint("Search: %", search_query.str), rgba(1,1,1,1));
    }
}
