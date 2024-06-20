#scope_file

#import "File";
#import "File_Utilities";
#import "Hash";
#import "Hash_Table";
#import "Math";
#import "String";
#import "Thread";
#import "Unicode";

Input :: #import "Input";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_search_query_key_pressed: Key;
search_query_key_pressed_on_frame: Table(Key, u64);

search_query: Search_Query;

inputting_search_query := false;

log_data :: Log_Data.{"album_art/library", false};

#scope_module

library_search_query :: *search_query;

process_library_input :: (mpd_connection: *MPD.connection, albums: [] *Album, library: Library_Data, queue: *Queue.Data, frame: u64, rows: int, columns: int) -> bool {

    context.logger_data = *log_data;

    move_cursor_one_row_up   :: () #expand { move_cursor_by_n_albums(`albums.count, -columns); }
    move_cursor_one_row_down :: () #expand { move_cursor_by_n_albums(`albums.count, +columns); }

    move_cursor_one_page_up   :: () #expand { move_cursor_by_n_albums(`albums.count, -rows * columns); }
    move_cursor_one_page_down :: () #expand { move_cursor_by_n_albums(`albums.count, +rows * columns); }

    move_cursor_to_next_search_result :: () #expand {
        if search_query.str == "" return;

        for i: 0..(`albums.count - 1) {
            album_index := (i + cursor.album_position + 1) % `albums.count;
            album := `albums[album_index];
            match := true;
            for s: split(search_query.str, SPACE) {
                if s.count == 0 continue;
                if !contains_nocase(album.artist_name, s) && !contains_nocase(album.name, s) {
                    match = false;
                    break;
                }
            }
            if match {
                `cursor.album_position = album_index;
                break;
            }
        }
    }
    move_cursor_to_prev_search_result :: () #expand {
        if search_query.str == "" return;

        for < i: (`albums.count - 1)..0 {
            album_index := (i + cursor.album_position) % `albums.count;
            album := `albums[album_index];
            match := true;
            for s: split(search_query.str, SPACE) {
                if s.count == 0 continue;
                if !contains_nocase(album.artist_name, s) && !contains_nocase(album.name, s) {
                    match = false;
                    break;
                }
            }
            if match {
                `cursor.album_position = album_index;
                break;
            }
        }
    }

    if !inputting_search_query {
        for Input.events_this_frame {
            if it.type == .KEYBOARD && it.key_pressed {
                if it.ctrl_pressed {
                    if it.key_code == {

                      case KEY_D;
                        table_set(*key_pressed_on_frame, .CTRL_D, frame);
                        last_key_pressed = .CTRL_D;
                        move_cursor_one_page_down();
                        break it;
                      case KEY_U;
                        table_set(*key_pressed_on_frame, .CTRL_U, frame);
                        last_key_pressed = .CTRL_U;
                        move_cursor_one_page_up();
                        break it;

                    }
                } else {
                    if it.key_code == {

                      case KEY_J;
                        table_set(*key_pressed_on_frame, .J, frame);
                        last_key_pressed = .J;
                        move_cursor_one_row_down();
                        break it;
                      case KEY_K;
                        table_set(*key_pressed_on_frame, .K, frame);
                        last_key_pressed = .K;
                        move_cursor_one_row_up();
                        break it;

                      case KEY_H;
                        table_set(*key_pressed_on_frame, .H, frame);
                        last_key_pressed = .H;
                        move_cursor_to_prev_album();
                        break it;
                      case KEY_L;
                        table_set(*key_pressed_on_frame, .L, frame);
                        last_key_pressed = .L;
                        move_cursor_to_next_album();
                        break it;

                      case KEY_G;
                        if it.shift_pressed {
                            cursor.album_position = albums.count - 1;
                        } else {
                            cursor.album_position = 0;
                        }
                        break it;

                      case KEY_O;
                        mpd_current_song := MPD.run_current_song(mpd_connection);
                        handle_errors("Getting current song");
                        if !mpd_current_song break;
                        uri := to_string(MPD.song_get_uri(mpd_current_song));
                        for album, album_index: albums {
                            for song: album.songs {
                                if song.uri == uri {
                                    cursor.album_position = album_index;
                                    break;
                                }
                            }
                        }
                        break it;

                      // case KEY_R;
                      //   album_index := cursor.position;
                      //   album := albums[album_index];
                      //   album.thumbnail_texture = load_thumbnail_if_exists(albums[album_index]);

                      case .ENTER;
                        last_key_pressed = .ENTER;
                        table_set(*key_pressed_on_frame, .ENTER, frame);

                        if albums.count == 0 break it;
                        album := albums[cursor.album_position];
                        song_id_to_play := add_album_to_queue(library, album.artist_name, album.name);
                        if song_id_to_play >= 0 {
                            MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                            handle_errors("Playing first song in group added to queue");
                            Queue.update(mpd_connection, library, queue);
                            update_status(Queue.get_current_song(mpd_connection, queue));
                        }
                        break it;

                      case .SPACEBAR;
                        last_key_pressed = .SPACE;
                        table_set(*key_pressed_on_frame, .SPACE, frame);
                        album := albums[cursor.album_position];
                        add_album_to_queue(library, album.artist_name, album.name);
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

                      case KEY_I;
                        if albums.count > 0 {
                            current_album_art_subview = .ALBUM;
                        }
                        break it;

                    }
                }
            }
        }

        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       move_cursor_one_row_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       move_cursor_one_row_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .H)       move_cursor_to_prev_album();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .L)       move_cursor_to_next_album();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  move_cursor_one_page_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  move_cursor_one_page_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .N)       move_cursor_to_next_search_result();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .SHIFT_N) move_cursor_to_prev_search_result();
    } else {

        /*****************************
        * user entering search query *
        *****************************/

        move_cursor_to_first_search_result :: () #expand {
            if search_query.str == "" return;

            for album, album_index: albums {
                match := true;
                for s: split(search_query.str, SPACE) {
                    if s.count == 0 continue;
                    if !contains_nocase(album.artist_name, s) && !contains_nocase(album.name, s) {
                        match = false;
                        break;
                    }
                }
                if match {
                    `cursor.album_position = album_index;
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
                    if it.ctrl_pressed {
                        if it.key_code == {

                          case KEY_U;
                                last_search_query_key_pressed = .CTRL_U;
                                search_query.str.count = 0;
                                break it;

                        }
                    } else {
                        if it.key_code == {

                          case .BACKSPACE;
                            last_search_query_key_pressed = .BACKSPACE;
                            table_set(*search_query_key_pressed_on_frame, .BACKSPACE, frame);
                            backspace_search_query(*search_query);
                            move_cursor_to_first_search_result();
                            break it;

                          case .ENTER; #through;
                          case .ESCAPE;
                            last_search_query_key_pressed = .ESCAPE;
                            inputting_search_query = false;
                            break it;

                        }
                    }
                }
            }
        }

        if key_held_passed_threshold(search_query_key_pressed_on_frame, last_search_query_key_pressed, frame, .BACKSPACE) { backspace_search_query(*search_query); move_cursor_to_first_search_result(); }
    }

    return inputting_search_query;
}

draw_library_frame :: (albums: [] *Album, library_allocator: Allocator, boundary: View_Boundary, rows: int, columns: int, x_padding_between_album_covers: s32, y_padding_between_album_covers: s32, highlight_width: s32) {
    font := fonts.regular;

    context.logger_data = *log_data;

    if albums.count > 0 {

        Entry :: struct {
            artist_name : string;
            album_name  : string;
            texture     : *Simp.Texture;
            selected    : bool;
        };
        entries_to_draw: [] Entry;

        /************************************************
        * determine the set of album thumbnails to draw *
        ************************************************/

        {
            album_index: s64 = 0;
            { // calculate index of first album to display
                index_of_first_album_in_current_row := cursor.album_position / columns * columns;
                index_of_first_album_on_last_page   := max(0, (albums.count - 1 - (rows - 1) * columns) / columns * columns);
                number_of_albums_in_half_page       := ((rows - 1) / 2) * columns;

                if index_of_first_album_in_current_row > index_of_first_album_on_last_page { // we're on the last page
                    album_index = index_of_first_album_on_last_page;
                } else if index_of_first_album_in_current_row > number_of_albums_in_half_page { // we're on a column after the first but before the last page
                    album_index = index_of_first_album_in_current_row - number_of_albums_in_half_page;
                }
            }

            num_entries_to_draw := min(albums.count - album_index, rows * columns);
            entries_to_draw = NewArray(num_entries_to_draw, Entry, false,, temp);

            max_characters_in_column := thumbnail_slot_width / font.w_width;
            for i: 0..entries_to_draw.count-1 {
                album := albums[album_index];

                entry: Entry;
                entry.artist_name = create_temp_display_string_of_max_length(album.artist_name, max_characters_in_column);
                entry.album_name  = create_temp_display_string_of_max_length(album.name,        max_characters_in_column);

                if !album.thumbnail_texture {
                    album.thumbnail_texture = load_thumbnail_if_exists(albums[album_index], library_allocator);
                }
                entry.texture  = album.thumbnail_texture;
                entry.selected = album_index == cursor.album_position;

                entries_to_draw[i] = entry;
                album_index += 1;
            }
        }

        /****************
        * draw the page *
        ****************/

        {
            x := boundary.left + highlight_width;
            y := boundary.top - highlight_width;

            row, column := 0;
            for entry: entries_to_draw {
                using entry;

                { // album name
                    text_width := Simp.prepare_text(font, album_name);
                    text_x := x + thumbnail_slot_width / 2 - text_width / 2;
                    text_y := y - thumbnail_slot_height - highlight_width - line_height;

                    if selected {
                        x0 := cast(float)text_x - font.w_width;
                        x1 := x0 + text_width + 2 * font.w_width;
                        y0, y1 := get_highlight_y_range(font, text_y);

                        Simp.set_shader_for_color();
                        Simp.immediate_quad(x0, y0, x1, y1, rgba(1,1,1,1));
                        Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                    } else {
                        Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                    }
                }
                { // artist name
                    text_width := Simp.prepare_text(font, artist_name);
                    text_x := x + thumbnail_slot_width / 2 - text_width / 2;
                    text_y := y - thumbnail_slot_height - highlight_width - 2 * (line_height);

                    if selected {
                        x0 := cast(float)text_x - font.w_width;
                        x1 := x0 + text_width + 2 * font.w_width;
                        y0, y1 := get_highlight_y_range(font, text_y);

                        Simp.set_shader_for_color();
                        Simp.immediate_quad(x0, y0, x1, y1, rgba(1,1,1,1));
                        Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                    } else {
                        Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                    }
                }

                if selected { // highlight album under cursor
                    for i: 0..highlight_width {
                        c := 1.0 - i / cast(float)highlight_width;
                        line_width := highlight_width - i + 4;
                        Simp.set_shader_for_color();
                        Simp.immediate_quad(
                            cast(float)x - line_width,
                            cast(float)y + line_width,
                            cast(float)x + thumbnail_slot_width  + line_width,
                            cast(float)y - thumbnail_slot_height - line_width,
                            rgba(c,c,c,1)
                        );
                    }
                    Simp.set_shader_for_color();
                }

                if texture { // draw the album cover thumbnail if we were able to load it
                    Simp.set_shader_for_images(texture);
                    Simp.immediate_begin();
                    // scale the display height of the cover
                    cover_display_height := min(cast(float)thumbnail_slot_height, cast(float)thumbnail_slot_width * cast(float)texture.height/texture.width);
                    height_difference := thumbnail_slot_height - cover_display_height;
                    Simp.immediate_quad(
                        xx x,
                        y - thumbnail_slot_height + height_difference / 2,
                        cast(float)x + thumbnail_slot_width,
                        y - height_difference / 2,
                        rgba(1,1,1,1),
                    );
                    Simp.immediate_flush();
                } else {
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(xx x, xx y, cast(float)x + thumbnail_slot_width, cast(float)y - thumbnail_slot_height, rgba(0,0,0,1));
                }

                column += 1;
                if column == columns {
                    row += 1;
                    column = 0;
                    x = boundary.left + highlight_width;
                    y -= thumbnail_slot_height + 2 * (line_height + highlight_width);
                    y -= y_padding_between_album_covers;
                } else {
                    x += thumbnail_slot_width;
                    x += x_padding_between_album_covers;
                }
            }
        }
    }

    if inputting_search_query {
        // TODO: need to ensure the x/y here won't overlap with anything else
        Simp.draw_text(font, boundary.left, boundary.bottom, tprint("Search: %", search_query.str), rgba(1,1,1,1));
    }
}

load_thumbnail_if_exists :: (album: *Album, allocator: Allocator) -> *Simp.Texture {

    context.logger_data = *log_data;

    lock(*album.mutex);
    defer unlock(*album.mutex);

    /*****************
    * load thumbnail *
    *****************/

    thumbnail_path := tprint("%/%-%x.bmp", config.album_cover_directory, get_hash(tprint("%-%", album.artist_name, album.name)), THUMBNAIL_WIDTH);
    texture: *Simp.Texture;
    if file_exists(thumbnail_path) {
        texture_load_context := context;
        texture_load_context.allocator = allocator;
        push_context texture_load_context {
            texture = New(Simp.Texture);
            if !Simp.texture_load_from_file(texture, thumbnail_path) {
                log("Failed to load thumbnail from memory for % - %", album.artist_name, album.name);
                free(texture);
                return null;
            }
        }
    }

    return texture;
}
