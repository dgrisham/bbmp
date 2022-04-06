#scope_file

#import "File";
#import "File_Utilities";
#import "Hash";
#import "Hash_Table";
#import "Math";
#import "Thread";
#import "Unicode";

Input :: #import "Input";

last_library_key_pressed: Key;
library_key_pressed_on_frame: Table(Key, u64);

#scope_module

process_library_input :: (mpd_connection: *MPD.connection, albums: [..] *Album, library: Library_Data, queue: *Queue.Data, frame: u64, rows: int, columns: int) {

    move_cursor_one_row_up   :: () #expand { move_cursor_by_n_albums(`albums.count, -columns); }
    move_cursor_one_row_down :: () #expand { move_cursor_by_n_albums(`albums.count, +columns); }

    move_cursor_one_page_up   :: () #expand { move_cursor_by_n_albums(`albums.count, -rows * columns); }
    move_cursor_one_page_down :: () #expand { move_cursor_by_n_albums(`albums.count, +rows * columns); }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    table_set(*library_key_pressed_on_frame, .J, frame);
                    last_library_key_pressed = .J;
                    move_cursor_one_row_down();
                    break it;
                  case KEY_K;
                    table_set(*library_key_pressed_on_frame, .K, frame);
                    last_library_key_pressed = .K;
                    move_cursor_one_row_up();
                    break it;

                  case KEY_H;
                    table_set(*library_key_pressed_on_frame, .H, frame);
                    last_library_key_pressed = .H;
                    move_cursor_to_prev_album();
                    break it;
                  case KEY_L;
                    table_set(*library_key_pressed_on_frame, .L, frame);
                    last_library_key_pressed = .L;
                    move_cursor_to_next_album();
                    break it;

                  case KEY_G;
                    if it.shift_pressed {
                        cursor.album_position = albums.count - 1;
                    } else {
                        cursor.album_position = 0;
                    }
                    break it;

                  case KEY_D;
                    if it.ctrl_pressed {
                        table_set(*library_key_pressed_on_frame, .CTRL_D, frame);
                        last_library_key_pressed = .CTRL_D;
                        move_cursor_one_page_down();
                    }
                    break it;
                  case KEY_U;
                    if it.ctrl_pressed {
                        table_set(*library_key_pressed_on_frame, .CTRL_U, frame);
                        last_library_key_pressed = .CTRL_U;
                        move_cursor_one_page_up();
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
                    last_library_key_pressed = .ENTER;
                    table_set(*library_key_pressed_on_frame, .ENTER, frame);
                    album := albums[cursor.album_position];
                    song_id_to_play := add_album_to_queue(library, album.artist_name, album.name);
                    if song_id_to_play >= 0 {
                        assert(mpd_connection != null);
                        MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                        handle_errors("Playing first song in group added to queue");
                        Queue.update(mpd_connection, queue);
                        update_status(Queue.get_current_song(mpd_connection, queue));
                    }
                    break it;

                  case .SPACEBAR;
                    last_library_key_pressed = .SPACE;
                    table_set(*library_key_pressed_on_frame, .SPACE, frame);
                    album := albums[cursor.album_position];
                    add_album_to_queue(library, album.artist_name, album.name);
                    break it;

                  case KEY_I;
                    current_album_art_subview = .ALBUM;
                    break it;

                }
            }

        }
    }

    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .J)       move_cursor_one_row_down();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .K)       move_cursor_one_row_up();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .H)       move_cursor_to_prev_album();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .L)       move_cursor_to_next_album();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .CTRL_D)  move_cursor_one_page_down();
    if key_held_passed_threshold(library_key_pressed_on_frame, last_library_key_pressed, frame, .CTRL_U)  move_cursor_one_page_up();
}

draw_library_frame :: (albums: [..] *Album, font: *Simp.Dynamic_Font, header_bottom: int, rows: int, columns: int, total_width: s32, total_height: int, thumbnail_slot_width: s32, thumbnail_slot_height: s32, Y_PADDING_BELOW_HEADER: s32) {

    Entry :: struct {
        artist_name : string;
        album_name  : string;
        texture     : *Simp.Texture;
        selected    : bool;
    };
    entries_to_draw: [..] Entry;
    entries_to_draw.allocator = __temporary_allocator;

    {
        max_entries_to_draw := rows * columns;
        array_reserve(*entries_to_draw, max_entries_to_draw);

        album_index: s64 = 0;
        { // calculate index of first album to display
            index_of_first_album_in_current_row := cursor.album_position / columns * columns;
            index_of_first_album_on_last_page   := (albums.count - 1 - (rows - 1) * columns) / columns * columns;
            number_of_albums_in_half_page       := ((rows - 1) / 2) * columns;

            if index_of_first_album_in_current_row > index_of_first_album_on_last_page { // we're on the last page
                album_index = index_of_first_album_on_last_page;
            } else if index_of_first_album_in_current_row > number_of_albums_in_half_page { // we're on a column after the first but before the last page
                album_index = index_of_first_album_in_current_row - number_of_albums_in_half_page;
            }
        }

        max_characters_in_column := thumbnail_slot_width / font.w_width;
        while entries_to_draw.count < max_entries_to_draw {
            album := albums[album_index];

            entry: Entry;
            entry.artist_name = create_temp_display_string_of_max_length(album.artist_name, max_characters_in_column);
            entry.album_name  = create_temp_display_string_of_max_length(album.name,        max_characters_in_column);

            if !album.thumbnail_texture {
                album.thumbnail_texture = load_thumbnail_if_exists(albums[album_index]);
            }
            entry.texture  = album.thumbnail_texture;
            entry.selected = album_index == cursor.album_position;

            array_add(*entries_to_draw, entry);

            album_index += 1;
            if album_index == albums.count {
                break;
            }
        }
    }

    {
        TEXT_PADDING_Y :: 5;
        SELECTED_COVER_HIGHLIGHT_WIDTH :: 8;
        HORIZONTAL_PADDING := cast(s32) ((total_width  - columns * thumbnail_slot_width) / (columns - 1));
        EXTRA_PADDING_BETWEEN_ROWS :: 5;
        VERTICAL_PADDING   := cast(s32) ((total_height - rows * (thumbnail_slot_height + 2 * (font.character_height + TEXT_PADDING_Y + SELECTED_COVER_HIGHLIGHT_WIDTH))) / (rows - 1));

        x := X_MARGIN_SIZE;
        y := header_bottom - Y_PADDING_BELOW_HEADER;

        row, column := 0;
        for entry: entries_to_draw {

            { // album name
                text_width := Simp.prepare_text(font, entry.album_name);
                text_x := x + thumbnail_slot_width / 2 - text_width / 2;
                text_y := y - thumbnail_slot_height - SELECTED_COVER_HIGHLIGHT_WIDTH - (TEXT_PADDING_Y + font.character_height);

                if entry.selected {
                    rectangle_width := thumbnail_slot_width;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)text_x - 10, cast(float)text_y - 5, cast(float)text_x + text_width + 10, cast(float)text_y + font.character_height, rgba(1,1,1,1));
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                } else {
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                }
            }
            { // artist name
                text_width := Simp.prepare_text(font, entry.artist_name);
                text_x := x + thumbnail_slot_width / 2 - text_width / 2;
                text_y := y - thumbnail_slot_height - SELECTED_COVER_HIGHLIGHT_WIDTH - 2 * (TEXT_PADDING_Y + font.character_height);

                if entry.selected {
                    rectangle_width := thumbnail_slot_width;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)text_x - 10, cast(float)text_y - 5, cast(float)text_x + text_width + 10, cast(float)text_y + font.character_height, rgba(1,1,1,1));
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                } else {
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                }
            }

            if entry.selected {
                for i: 0..SELECTED_COVER_HIGHLIGHT_WIDTH {
                    c := 1.0 - i / cast(float)SELECTED_COVER_HIGHLIGHT_WIDTH;
                    highlight_width := SELECTED_COVER_HIGHLIGHT_WIDTH - i + 4;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(
                        cast(float)x - highlight_width,
                        cast(float)y + highlight_width,
                        cast(float)x + thumbnail_slot_width  + highlight_width,
                        cast(float)y - thumbnail_slot_height - highlight_width,
                        rgba(c,c,c,1)
                    );
                }
                Simp.set_shader_for_color();
            }

            if entry.texture {
                Simp.set_shader_for_images(entry.texture);
                Simp.immediate_begin();
                // scale the display height of the cover
                cover_display_height := min(cast(float)thumbnail_slot_height, cast(float)thumbnail_slot_width * cast(float)entry.texture.height/entry.texture.width);
                height_difference := thumbnail_slot_height - cover_display_height;
                Simp.immediate_quad(
                    xy(cast(float)x, cast(float)y - thumbnail_slot_height + height_difference / 2),
                    xy(cast(float)x + thumbnail_slot_width, cast(float)y - thumbnail_slot_height + height_difference / 2),
                    xy(cast(float)x + thumbnail_slot_width, cast(float)y - height_difference / 2),
                    xy(cast(float)x, cast(float)y - height_difference / 2)
                );
                Simp.immediate_flush();

            } else {
                Simp.set_shader_for_color();
                Simp.immediate_quad(cast(float)x, cast(float)y, cast(float)x + thumbnail_slot_width, cast(float)y - thumbnail_slot_height, rgba(0,0,0,1));
            }

            column += 1;
            if column == columns {
                row += 1;
                column = 0;
                x = X_MARGIN_SIZE;
                y -= thumbnail_slot_height + EXTRA_PADDING_BETWEEN_ROWS + 2 * (font.character_height + TEXT_PADDING_Y + SELECTED_COVER_HIGHLIGHT_WIDTH);
                y -= VERTICAL_PADDING;
            } else {
                x += thumbnail_slot_width;
                x += HORIZONTAL_PADDING;
            }
        }
    }
}

load_thumbnail_if_exists :: (album: *Album) -> *Simp.Texture {

    lock(*album.mutex);
    defer unlock(*album.mutex);
    if !album.thumbnail_bitmap {
        return null;
    }
    defer { Simp.deinit(album.thumbnail_bitmap); free(album.thumbnail_bitmap); };

    texture := New(Simp.Texture);
    if !Simp.texture_load_from_bitmap(texture, album.thumbnail_bitmap) {
        log("Failed to load thumbnail from memory for % - %", album.artist_name, album.name);
        free(texture);
        return null;
    }

    return texture;
}