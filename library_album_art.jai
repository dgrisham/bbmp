#import "Hash_Table";
#import "Unicode";
#import "File_Utilities";
#import "Hash";
#import "File";

library_album_art: struct {
    albums : [..] *Album;
}

library_album_art_cursor: struct {
    album_position : int = 0;
    song_position  : int = 0;
}

load_library_album_art :: () {
    array_resize(*library_album_art.albums, library.stats.number_of_albums);
    i := 0;
    for artist_name: library.artist_names_sorted {
        artist_ptr := table_find_pointer(library.artists, artist_name);
        assert(artist_ptr != null, "Failed to find artist '%' in table when loading library album art data", artist_name);

        for album_name: artist_ptr.album_names_sorted_by_date {
            album_ptr := table_find_pointer(artist_ptr.albums, album_name);
            assert(album_ptr != null, "Failed to find album '%' - '%' in table when loading library album art data", artist_name, album_name);

            library_album_art.albums[i] = album_ptr;
            i += 1;
        }
    }
}

#load "album.jai";

SHOW_CURRENT_ALBUM := false;

THUMBNAIL_SLOT_WIDTH  : s32 = 200;
THUMBNAIL_SLOT_HEIGHT : s32 = 200;

library_album_art_event_loop :: (frame: u64, header_bottom: int) {

    Y_PADDING_BELOW_HEADER := Y_MARGIN_SIZE;

    total_height := header_bottom - Y_PADDING_BELOW_HEADER - 2 * Y_MARGIN_SIZE;
    rows := total_height / THUMBNAIL_SLOT_HEIGHT - 1;

    total_width := cast(s32)display_width();
    columns := total_width / THUMBNAIL_SLOT_WIDTH - 1;

    song_list_height := header_bottom - 3 * Y_MARGIN_SIZE - 3 * (TEXT_PADDING_Y + font.character_height) - TEXT_PADDING_Y;
    album_songs_in_page := cast(int)(song_list_height - font.character_height) / (font.character_height + TEXT_PADDING_Y);

    OLD_SHOW_CURRENT_ALBUM := SHOW_CURRENT_ALBUM;
    if SHOW_CURRENT_ALBUM {
        album_process_input(frame, header_bottom, album_songs_in_page, library_album_art.albums[library_album_art_cursor.album_position]);
    } else {
        library_album_art_process_input(frame, rows, columns);
    }

    if SHOW_CURRENT_ALBUM {
        draw_album_frame(library_album_art.albums[library_album_art_cursor.album_position], !OLD_SHOW_CURRENT_ALBUM, header_bottom, album_songs_in_page);
    } else {
        library_album_art_draw_one_frame(header_bottom, rows, columns, total_width, total_height, Y_PADDING_BELOW_HEADER);
    }
}

last_library_album_art_key_pressed: Key;
library_album_art_key_pressed_on_frame: Table(Key, u64);

library_album_art_init_repeatable_keys :: () {
    table_set(*library_album_art_key_pressed_on_frame, .J,      0);
    table_set(*library_album_art_key_pressed_on_frame, .K,      0);
    table_set(*library_album_art_key_pressed_on_frame, .L,      0);
    table_set(*library_album_art_key_pressed_on_frame, .H,      0);
    table_set(*library_album_art_key_pressed_on_frame, .CTRL_D, 0);
    table_set(*library_album_art_key_pressed_on_frame, .CTRL_U, 0);
}

library_album_art_move_cursor :: (amount: int) #expand {
    `library_album_art_cursor.album_position += amount;
    if library_album_art_cursor.album_position < 0 {
        library_album_art_cursor.album_position = 0;
    } else if `library_album_art_cursor.album_position > library_album_art.albums.count - 1 {
        `library_album_art_cursor.album_position = library_album_art.albums.count - 1;
    }
}

library_album_art_move_cursor_left  :: () #expand { library_album_art_move_cursor(-1); }
library_album_art_move_cursor_right :: () #expand { library_album_art_move_cursor(1); }

library_album_art_process_input :: (frame: u64, rows: int, columns: int) {

    library_album_art_move_cursor_up   :: () #expand { library_album_art_move_cursor(-columns); }
    library_album_art_move_cursor_down :: () #expand { library_album_art_move_cursor(columns); }

    library_album_art_move_cursor_left  :: () #expand { library_album_art_move_cursor(-1); }
    library_album_art_move_cursor_right :: () #expand { library_album_art_move_cursor(1); }

    library_album_art_move_cursor_one_page_up   :: () #expand { library_album_art_move_cursor(-rows * columns); }
    library_album_art_move_cursor_one_page_down :: () #expand { library_album_art_move_cursor(rows * columns); }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_J;
                    table_set(*library_album_art_key_pressed_on_frame, .J, frame);
                    last_library_album_art_key_pressed = .J;
                    library_album_art_move_cursor_down();
                    break it;
                  case KEY_K;
                    table_set(*library_album_art_key_pressed_on_frame, .K, frame);
                    last_library_album_art_key_pressed = .K;
                    library_album_art_move_cursor_up();
                    break it;

                  case KEY_H;
                    table_set(*library_album_art_key_pressed_on_frame, .H, frame);
                    last_library_album_art_key_pressed = .H;
                    library_album_art_move_cursor_left();
                    break it;
                  case KEY_L;
                    table_set(*library_album_art_key_pressed_on_frame, .L, frame);
                    last_library_album_art_key_pressed = .L;
                    library_album_art_move_cursor_right();
                    break it;

                  case KEY_G;
                    if it.shift_pressed {
                        library_album_art_cursor.album_position = library_album_art.albums.count - 1;
                    } else {
                        library_album_art_cursor.album_position = 0;
                    }
                    break it;

                  case KEY_D;
                    if it.ctrl_pressed {
                        table_set(*library_album_art_key_pressed_on_frame, .CTRL_D, frame);
                        last_library_album_art_key_pressed = .CTRL_D;
                        library_album_art_move_cursor_one_page_down();
                    }
                    break it;
                  case KEY_U;
                    if it.ctrl_pressed {
                        table_set(*library_album_art_key_pressed_on_frame, .CTRL_U, frame);
                        last_library_album_art_key_pressed = .CTRL_U;
                        library_album_art_move_cursor_one_page_up();
                    }
                    break it;

                  case KEY_O;
                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("Getting current song");
                    if !mpd_current_song break;
                    uri := to_string(MPD.song_get_uri(mpd_current_song));
                    for album, album_index: library_album_art.albums {
                        for song: album.songs {
                            if song.uri == uri {
                                library_album_art_cursor.album_position = album_index;
                                break;
                            }
                        }
                    }
                    break it;

                  // case KEY_R;
                  //   album_index := library_album_art_cursor.position;
                  //   album := library_album_art.albums[album_index];
                  //   album.thumbnail_texture = load_thumbnail_if_exists(album_index);

                  case .ENTER;
                    last_library_album_art_key_pressed = .ENTER;
                    table_set(*library_album_art_key_pressed_on_frame, .ENTER, frame);
                    album := library_album_art.albums[library_album_art_cursor.album_position];
                    song_id_to_play := add_album_to_queue(album.artist_name, album.name);
                    if song_id_to_play >= 0 {
                        assert(mpd_connection != null);
                        MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
                        handle_errors("Playing first song in group added to queue");
                        update_status();
                    }
                    break it;

                  case .SPACEBAR;
                    last_library_album_art_key_pressed = .SPACE;
                    table_set(*library_album_art_key_pressed_on_frame, .SPACE, frame);
                    album := library_album_art.albums[library_album_art_cursor.album_position];
                    add_album_to_queue(album.artist_name, album.name);
                    break it;

                  case KEY_I;
                    SHOW_CURRENT_ALBUM = true;
                    break it;

                }
            }

        }
    }

    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .J)       library_album_art_move_cursor_down();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .K)       library_album_art_move_cursor_up();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .H)       library_album_art_move_cursor_left();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .L)       library_album_art_move_cursor_right();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .CTRL_D)  library_album_art_move_cursor_one_page_down();
    if key_held_passed_threshold(library_album_art_key_pressed_on_frame, last_library_album_art_key_pressed, frame, .CTRL_U)  library_album_art_move_cursor_one_page_up();
}

ELLIPSIS :: u8.[226, 128, 166];
library_album_art_draw_one_frame :: (header_bottom: int, rows: int, columns: int, total_width: s32, total_height: int, Y_PADDING_BELOW_HEADER: s32) {

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
            index_of_first_album_in_current_row := library_album_art_cursor.album_position / columns * columns;
            index_of_first_album_on_last_page   := (library_album_art.albums.count - 1 - (rows - 1) * columns) / columns * columns;
            number_of_albums_in_half_page       := ((rows - 1) / 2) * columns;

            if index_of_first_album_in_current_row > index_of_first_album_on_last_page { // we're on the last page
                album_index = index_of_first_album_on_last_page;
            } else if index_of_first_album_in_current_row > number_of_albums_in_half_page { // we're on a column after the first but before the last page
                album_index = index_of_first_album_in_current_row - number_of_albums_in_half_page;
            }
        }

        max_characters_in_column := THUMBNAIL_SLOT_WIDTH / font.w_width;
        while entries_to_draw.count < max_entries_to_draw {
            album := library_album_art.albums[album_index];

            entry: Entry;
            entry.artist_name = create_temp_display_string_of_max_length(album.artist_name, max_characters_in_column);
            entry.album_name  = create_temp_display_string_of_max_length(album.name,        max_characters_in_column);

            if !album.thumbnail_texture {
                album.thumbnail_texture = load_thumbnail_if_exists(album_index);
            }
            entry.texture  = album.thumbnail_texture;
            entry.selected = album_index == library_album_art_cursor.album_position;

            array_add(*entries_to_draw, entry);

            album_index += 1;
            if album_index == library_album_art.albums.count {
                break;
            }
        }
    }

    {
        TEXT_PADDING_Y :: 5;
        SELECTED_COVER_HIGHLIGHT_WIDTH :: 8;
        HORIZONTAL_PADDING := cast(s32) ((total_width  - columns * THUMBNAIL_SLOT_WIDTH) / (columns - 1));
        EXTRA_PADDING_BETWEEN_ROWS :: 5;
        VERTICAL_PADDING   := cast(s32) ((total_height - rows * (THUMBNAIL_SLOT_HEIGHT + 2 * (font.character_height + TEXT_PADDING_Y + SELECTED_COVER_HIGHLIGHT_WIDTH))) / (rows - 1));

        x := X_MARGIN_SIZE;
        y := header_bottom - Y_PADDING_BELOW_HEADER;

        row, column := 0;
        for entry: entries_to_draw {

            { // album name
                text_width := Simp.prepare_text(font, entry.album_name);
                text_x := x + THUMBNAIL_SLOT_WIDTH / 2 - text_width / 2;
                text_y := y - THUMBNAIL_SLOT_HEIGHT - SELECTED_COVER_HIGHLIGHT_WIDTH - (TEXT_PADDING_Y + font.character_height);

                if entry.selected {
                    rectangle_width := THUMBNAIL_SLOT_WIDTH;
                    Simp.set_shader_for_color();
                    Simp.immediate_quad(cast(float)text_x - 10, cast(float)text_y - 5, cast(float)text_x + text_width + 10, cast(float)text_y + font.character_height, rgba(1,1,1,1));
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(0,0,0,1));
                } else {
                    Simp.draw_prepared_text(font, text_x, text_y, rgba(1,1,1,1));
                }
            }
            { // artist name
                text_width := Simp.prepare_text(font, entry.artist_name);
                text_x := x + THUMBNAIL_SLOT_WIDTH / 2 - text_width / 2;
                text_y := y - THUMBNAIL_SLOT_HEIGHT - SELECTED_COVER_HIGHLIGHT_WIDTH - 2 * (TEXT_PADDING_Y + font.character_height);

                if entry.selected {
                    rectangle_width := THUMBNAIL_SLOT_WIDTH;
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
                        cast(float)x + THUMBNAIL_SLOT_WIDTH  + highlight_width,
                        cast(float)y - THUMBNAIL_SLOT_HEIGHT - highlight_width,
                        rgba(c,c,c,1)
                    );
                }
                Simp.set_shader_for_color();
            }

            if entry.texture {
                Simp.set_shader_for_images(entry.texture);
                Simp.immediate_begin();
                // scale the display height of the cover
                cover_display_height := min(cast(float)THUMBNAIL_SLOT_HEIGHT, cast(float)THUMBNAIL_SLOT_WIDTH * cast(float)entry.texture.height/entry.texture.width);
                height_difference := THUMBNAIL_SLOT_HEIGHT - cover_display_height;
                Simp.immediate_quad(
                    xy(cast(float)x, cast(float)y - THUMBNAIL_SLOT_HEIGHT + height_difference / 2),
                    xy(cast(float)x + THUMBNAIL_SLOT_WIDTH, cast(float)y - THUMBNAIL_SLOT_HEIGHT + height_difference / 2),
                    xy(cast(float)x + THUMBNAIL_SLOT_WIDTH, cast(float)y - height_difference / 2),
                    xy(cast(float)x, cast(float)y - height_difference / 2)
                );
                Simp.immediate_flush();

            } else {
                Simp.set_shader_for_color();
                Simp.immediate_quad(cast(float)x, cast(float)y, cast(float)x + THUMBNAIL_SLOT_WIDTH, cast(float)y - THUMBNAIL_SLOT_HEIGHT, rgba(0,0,0,1));
            }

            column += 1;
            if column == columns {
                row += 1;
                column = 0;
                x = X_MARGIN_SIZE;
                y -= THUMBNAIL_SLOT_HEIGHT + EXTRA_PADDING_BETWEEN_ROWS + 2 * (font.character_height + TEXT_PADDING_Y + SELECTED_COVER_HIGHLIGHT_WIDTH);
                y -= VERTICAL_PADDING;
            } else {
                x += THUMBNAIL_SLOT_WIDTH;
                x += HORIZONTAL_PADDING;
            }
        }
    }
}

load_thumbnail_if_exists :: (album_index: s64) -> *Simp.Texture {

    album := library_album_art.albums[album_index];
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
