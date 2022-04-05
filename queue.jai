#scope_file

#import "Basic";
#import "Hash_Table";
#import "Math";

#import "common";

MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";
Input :: #import "Input";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

cursor: struct {
    position := 0;
};

#scope_export

Data :: struct {
    songs: [..] Song;
    version: u32;
}

load :: (mpd_connection: *MPD.connection) -> *Data {

    queue := New(Data);

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    if !status { print("Status is null, not refreshing queue\n"); return null; }
    mpd_queue_length := MPD.status_get_queue_length(status);
    queue.version = MPD.status_get_queue_version(status);
    MPD.status_free(status);

    // reserve the space but don't resize the array, in case we're missing metadata
    // for any songs while we're iterating below
    array_reserve(*queue.songs, mpd_queue_length);

    assert(mpd_connection != null);
    MPD.send_list_queue_meta(mpd_connection);
    handle_errors("Retrieving MPD metadata");

    entity := MPD.recv_entity(mpd_connection);
    handle_errors("Receiving first entity");

    while entity {
        if MPD.entity_get_type(entity) == .SONG {
            mpd_song  := MPD.entity_get_song(entity);

            song: Song;
            song.track    = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK       , 0));
            song.artist   = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0));
            song.album    = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM       , 0));
            song.name     = copy_from_c_string(MPD.song_get_tag(mpd_song, .TITLE       , 0));
            song.uri      = copy_from_c_string(MPD.song_get_uri(mpd_song));
            song.duration = MPD.song_get_duration(mpd_song);

            array_add(*queue.songs, song);
        }

        MPD.entity_free(entity);
        entity = MPD.recv_entity(mpd_connection);
        handle_errors("Receiving entity");
    }

    array_resize(*queue.songs, queue.songs.count);

    return queue;
}

update :: (mpd_connection: *MPD.connection, queue: *Data) {

    status := MPD.run_status(mpd_connection);
    handle_errors("Getting MPD status");
    // TODO: this check is okay to make but is also mainly a workaround for the mpd connection dying bug
    if !status { print("Status is null, not refreshing queue\n"); return; }
    mpd_queue_length := MPD.status_get_queue_length(status);

    old_version := queue.version;
    queue.version = MPD.status_get_queue_version(status);

    MPD.status_free(status);

    assert(mpd_connection != null);
    MPD.send_queue_changes_meta(mpd_connection, old_version);
    handle_errors("Retrieving MPD metadata");

    mpd_song := MPD.recv_song(mpd_connection);
    handle_errors("Receiving first updated queue song");

    while mpd_song {
        queue_song_position := MPD.song_get_pos(mpd_song);
        mpd_artist := MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0);
        mpd_album  := MPD.song_get_tag(mpd_song, .ALBUM       , 0);
        mpd_title  := MPD.song_get_tag(mpd_song, .TITLE       , 0);
        mpd_date   := MPD.song_get_tag(mpd_song, .DATE        , 0);

        song: Song;
        song.track    = copy_from_c_string(MPD.song_get_tag(mpd_song, .TRACK       , 0));
        song.artist   = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM_ARTIST, 0));
        song.album    = copy_from_c_string(MPD.song_get_tag(mpd_song, .ALBUM       , 0));
        song.name     = copy_from_c_string(MPD.song_get_tag(mpd_song, .TITLE       , 0));
        song.uri      = copy_from_c_string(MPD.song_get_uri(mpd_song));
        song.duration = MPD.song_get_duration(mpd_song);

        if queue_song_position < queue.songs.count {
            free(queue.songs[queue_song_position]);
            queue.songs[queue_song_position] = song;
        } else {
            array_add(*queue.songs, song);
        }

        MPD.song_free(mpd_song);
        mpd_song = MPD.recv_song(mpd_connection);
        handle_errors("Receiving updated queue song");
    }

    for i: mpd_queue_length..(queue.songs.count - 1) {
        free(queue.songs[i]);
    }
    array_resize(*queue.songs, mpd_queue_length);
}

get_current_song :: (mpd_connection: *MPD.connection, queue: Data) -> *Song {
    mpd_status := MPD.run_status(mpd_connection);
    handle_errors("Retrieving MPD status");
    MPD.response_finish(mpd_connection);

    queue_song_position := MPD.status_get_song_pos(mpd_status);
    if queue_song_position < 0 return null;
    assert(queue_song_position < queue.songs.count);
    return *queue.songs[queue_song_position];
}

event_loop :: (mpd_connection: *MPD.connection, queue: *Data, frame: u64, font: *Simp.Dynamic_Font, display_width: s32, header_bottom: int) {

    items_in_page := (header_bottom - 2 * Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);

    queue_shift_selected_item_down :: () #expand {
        if cursor.position < `queue.songs.count - 1 {
            MPD.run_swap(`mpd_connection, cast(u32)cursor.position, cast(u32)cursor.position + 1);
            handle_errors("Moving song down in queue");
            update(`mpd_connection, `queue);
            `cursor.position += 1;
        }
    }
    queue_move_cursor_down :: () #expand {
        `cursor.position += 1;
    }

    queue_shift_selected_item_up :: () #expand {
        if cursor.position > 0 {
            MPD.run_swap(mpd_connection, cast(u32)cursor.position, cast(u32)cursor.position - 1);
            handle_errors("Moving song up in queue");
            update(`mpd_connection, `queue);
            `cursor.position -= 1;
        }
    }
    queue_move_cursor_up :: () #expand {
        `cursor.position -= 1;
    }

    queue_move_cursor_one_page_down :: () #expand {
        `cursor.position += items_in_page;
    }
    queue_move_cursor_one_page_up :: () #expand {
        `cursor.position -= items_in_page;
    }

    queue_remove_selected_song :: () #expand {
        if cursor.position >= 0 && cursor.position <= queue.songs.count {
            MPD.run_delete(mpd_connection, cast(u32)cursor.position);
            handle_errors("Removing song from queue");
            update(`mpd_connection, `queue);
            update_status(get_current_song(`mpd_connection, `queue));
        }
    }

    queue_play_selected_song :: () #expand {
        MPD.run_play_pos(mpd_connection, cast(u32)cursor.position);
        handle_errors("Playing queue song");
            update_status(get_current_song(`mpd_connection, `queue));
    }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    if it.shift_pressed {
                        table_set(*key_pressed_on_frame, .SHIFT_J, frame);
                        last_key_pressed = .SHIFT_J;
                        queue_shift_selected_item_down();
                    } else {
                        table_set(*key_pressed_on_frame, .J, frame);
                        last_key_pressed = .J;
                        queue_move_cursor_down();
                    }
                    break it;
                  case KEY_K;
                    if it.shift_pressed {
                        table_set(*key_pressed_on_frame, .SHIFT_K, frame);
                        last_key_pressed = .SHIFT_K;
                        queue_shift_selected_item_up();
                    } else {
                        table_set(*key_pressed_on_frame, .K, frame);
                        last_key_pressed = .K;
                        queue_move_cursor_up();
                    }
                    break it;

                  case KEY_D;
                    if it.ctrl_pressed {
                        table_set(*key_pressed_on_frame, .CTRL_D, frame);
                        last_key_pressed = .CTRL_D;
                        queue_move_cursor_one_page_down();
                    }
                    break it;
                  case KEY_U;
                    if it.ctrl_pressed {
                        table_set(*key_pressed_on_frame, .CTRL_U, frame);
                        last_key_pressed = .CTRL_U;
                        queue_move_cursor_one_page_up();
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
                    queue_remove_selected_song();
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
                    queue_play_selected_song();
                    break it;
                }
            }

        }
    }

    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       queue_move_cursor_down();
    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       queue_move_cursor_up();
    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_J) queue_shift_selected_item_down();
    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_K) queue_shift_selected_item_up();
    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  queue_move_cursor_one_page_down();
    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  queue_move_cursor_one_page_up();
    if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .X)       queue_remove_selected_song();

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
            rectangle_width : s32;
            entries         : [..] Display_Text;
        };

        {
            display_columns[0].entries.allocator = __temporary_allocator;
            display_columns[1].entries.allocator = __temporary_allocator;
            display_columns[2].entries.allocator = __temporary_allocator;
            display_columns[3].entries.allocator = __temporary_allocator;

            display_columns[0].width = cast(s32)(8 / 20.0 * display_width);
            display_columns[1].width = cast(s32)(5 / 20.0 * display_width);
            display_columns[2].width = cast(s32)(5 / 20.0 * display_width);
            display_columns[3].width = cast(s32)display_width - display_columns[0].width - display_columns[1].width - display_columns[2].width;

            index_start := max(0, min(queue.songs.count - items_in_page, cursor.position - items_in_page/ 2 + 1));
            index_end   := min(index_start + items_in_page, queue.songs.count) - 1;

            array_reserve(*display_columns[0].entries, index_end - index_start + 1);
            array_reserve(*display_columns[1].entries, index_end - index_start + 1);
            array_reserve(*display_columns[2].entries, index_end - index_start + 1);
            array_reserve(*display_columns[3].entries, index_end - index_start + 1);

            selected_index := cursor.position;

            for i: index_start..index_end {
                song := queue.songs[i];
                selected := i == selected_index;

                { // song name
                    max_characters_in_column := display_columns[0].width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.text = create_temp_display_string_of_max_length(song.name, max_characters_in_column);
                    display_text.selected = selected;
                    array_add(*display_columns[0].entries, display_text);
                }

                { // album name
                    max_characters_in_column := display_columns[1].width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.selected = selected;
                    display_text.text = create_temp_display_string_of_max_length(song.album, max_characters_in_column);
                    array_add(*display_columns[1].entries, display_text);
                }

                { // artist name
                    max_characters_in_column := display_columns[2].width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.selected = selected;
                    display_text.text = create_temp_display_string_of_max_length(song.artist, max_characters_in_column);
                    array_add(*display_columns[2].entries, display_text);
                }

                { // song duration
                    max_characters_in_column := display_columns[3].width / font.w_width - 2;
                    duration_time_string := left_pad(seconds_to_time_string(song.duration), #char " ", max_characters_in_column);
                    display_text: Display_Text;
                    display_text.selected = selected;
                    display_text.text = create_temp_display_string_of_max_length(duration_time_string, max_characters_in_column);
                    array_add(*display_columns[3].entries, display_text);
                }
            }
        }

        {
            top := header_bottom - 25;
            x := X_MARGIN_SIZE;
            for column_index: 0..display_columns.count - 1 {
                y := top;
                column_width := display_columns[column_index].width;

                for display_text: display_columns[column_index].entries {
                    if display_text.selected {
                        Simp.set_shader_for_color();
                        color := ifx column_index == 0 then rgba(1,1,1,1) else rgba(0.5, 0.5, 0.5, 1); // highlight the first column (song title) brighter than the rest
                        Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + column_width, cast(float)y + font.character_height, color);
                        Simp.draw_text(font, x, y, display_text.text, rgba(0,0,0,1));
                    } else {
                        Simp.draw_text(font, x, y, display_text.text, rgba(1,1,1,1));
                    }

                    y -= TEXT_PADDING_Y + font.character_height;
                }
                x += column_width;
            }
        }
    }
}
