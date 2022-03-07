album_cursor: struct {
    position: int = 0;
}

last_album_key_pressed: Key;
album_key_pressed_on_frame: Table(Key, u64);

album_init_repeatable_keys :: () {
    table_set(*album_key_pressed_on_frame, .J,       0);
    table_set(*album_key_pressed_on_frame, .K,       0);
    table_set(*album_key_pressed_on_frame, .CTRL_D,  0);
    table_set(*album_key_pressed_on_frame, .CTRL_U,  0);
    table_set(*album_key_pressed_on_frame, .SPACE,   0);
    table_set(*album_key_pressed_on_frame, .ENTER,   0);
}

album_process_input :: (frame: u64, album: *Album) {

    // TODO calculate based on window size
    items_in_page := 20;

    album_move_cursor_up            :: () #expand { `album_cursor.position -= 1; }
    album_move_cursor_down          :: () #expand { `album_cursor.position += 1; }
    album_move_cursor_one_page_up   :: () #expand { `album_cursor.position -= items_in_page; }
    album_move_cursor_one_page_down :: () #expand { `album_cursor.position += items_in_page; }

    album_add_selected_song_to_queue :: () -> int #expand {
        assert(mpd_connection != null);
        id := MPD.run_add_id(mpd_connection, to_c_string(`album.songs[`album_cursor.position].uri));
        handle_errors("Adding song to queue from album view");
        album_move_cursor_down();
        return id;
    }
    album_add_selected_song_to_queue_and_play :: () #expand {
        song_id_to_play := album_add_selected_song_to_queue();
        if song_id_to_play >= 0 {
            assert(mpd_connection != null);
            MPD.run_play_id(mpd_connection, cast(u32)song_id_to_play);
            handle_errors("Playing first song in group added to queue");
            update_status();
        }
    }

    for Input.events_this_frame {
        if it.type == {
          case .KEYBOARD;
            if it.key_pressed {
                if it.key_code == {

                  case KEY_I;
                    SHOW_CURRENT_ALBUM = false;
                    album_cursor.position = 0;
                    break it;

                  case KEY_J;
                    table_set(*album_key_pressed_on_frame, .J, frame);
                    last_album_key_pressed = .J;
                    album_move_cursor_down();
                    break it;
                  case KEY_K;
                    table_set(*album_key_pressed_on_frame, .K, frame);
                    last_album_key_pressed = .K;
                    album_move_cursor_up();
                    break it;

                  case KEY_D;
                    if it.ctrl_pressed {
                        table_set(*album_key_pressed_on_frame, .CTRL_D, frame);
                        last_album_key_pressed = .CTRL_D;
                        album_move_cursor_one_page_down();
                    }
                    break it;
                  case KEY_U;
                    if it.ctrl_pressed {
                        table_set(*album_key_pressed_on_frame, .CTRL_U, frame);
                        last_album_key_pressed = .CTRL_U;
                        album_move_cursor_one_page_up();
                    }
                    break it;

                  case KEY_O;
                    handle_mpd_idle_events();

                    mpd_current_song := MPD.run_current_song(mpd_connection);
                    handle_errors("Getting current song");
                    if !mpd_current_song break;
                    uri := to_string(MPD.song_get_uri(mpd_current_song));
                    for album, album_index: library_album_art.albums {
                        for song, song_index: album.songs {
                            if song.uri == uri {
                                // @Cleanup This is the first time we're updating cursor for another 'view'.
                                library_album_art_cursor.position = album_index;
                                album_cursor.position = song_index;
                                break;
                            }
                        }
                    }
                    break it;

                  case .SPACEBAR;
                    table_set(*album_key_pressed_on_frame, .SPACE, frame);
                    last_album_key_pressed = .SPACE;
                    album_add_selected_song_to_queue();
                    break it;

                  case .ENTER;
                    table_set(*album_key_pressed_on_frame, .ENTER, frame);
                    last_album_key_pressed = .ENTER;
                    album_add_selected_song_to_queue_and_play();
                    break it;
                }
            }
        }
    }

    if key_held_passed_threshold(album_key_pressed_on_frame, last_album_key_pressed, frame, .J)       album_move_cursor_down();
    if key_held_passed_threshold(album_key_pressed_on_frame, last_album_key_pressed, frame, .K)       album_move_cursor_up();
    if key_held_passed_threshold(album_key_pressed_on_frame, last_album_key_pressed, frame, .CTRL_D)  album_move_cursor_one_page_down();
    if key_held_passed_threshold(album_key_pressed_on_frame, last_album_key_pressed, frame, .CTRL_U)  album_move_cursor_one_page_up();
    if key_held_passed_threshold(album_key_pressed_on_frame, last_album_key_pressed, frame, .SPACE)   album_add_selected_song_to_queue();
    if key_held_passed_threshold(album_key_pressed_on_frame, last_album_key_pressed, frame, .ENTER)   album_add_selected_song_to_queue_and_play();

    if album_cursor.position < 0 {
        album_cursor.position = 0;
    } else if album_cursor.position > album.songs.count - 1 {
        album_cursor.position = album.songs.count - 1;
    }
}

loaded_album: struct {
    artist_name: string;
    album_name: string;
    art_texture: *Simp.Texture;
    art_loaded: bool = false;
}

COVER_DISPLAY_WIDTH :: 600;
album_draw_one_frame :: (album: *Album, load_current_album_cover: bool) {

    if loaded_album.art_texture == null loaded_album.art_texture = New(Simp.Texture);
    if album.artist_name != loaded_album.artist_name || album.name != loaded_album.album_name {
        free(loaded_album.artist_name);
        free(loaded_album.album_name);
        loaded_album.artist_name = copy_string(album.artist_name);
        loaded_album.album_name  = copy_string(album.name);
        loaded_album.art_loaded  = false;

        load_current_album_cover = true;
    }
    if load_current_album_cover {
        if album.cover_path != "" {
            display_art_path := tprint("%/%-%x.bmp", THUMBNAIL_DIRECTORY, get_hash(tprint("%-%", album.artist_name, album.name)), COVER_DISPLAY_WIDTH);
            if file_exists(display_art_path) {
                start := get_current_file_time();
                if !Simp.texture_load_from_file(loaded_album.art_texture, display_art_path) {
                    log("Failed to load display art for % - %", album.artist_name, album.name, flags=.ERROR);
                } else {
                    log("display album art load time: %\n", (get_current_file_time() - start) / 10000.0);
                    loaded_album.art_loaded = true;
                }
            }
        }
    }

    cover_display_width  := cast(float)COVER_DISPLAY_WIDTH;
    COVER_X := cast(float)window_width  / 2 - cover_display_width - 100;
    COVER_Y := cast(float)window_height / 2 - COVER_DISPLAY_WIDTH / 2;
    if loaded_album.art_loaded {
        cover_display_height := cast(float)COVER_DISPLAY_WIDTH * cast(float)loaded_album.art_texture.height/loaded_album.art_texture.width;

        Simp.set_shader_for_images(loaded_album.art_texture);
        Simp.immediate_begin();

        v2 :: make_vector2;
        Simp.immediate_quad(
            xy(COVER_X                      , COVER_Y),
            xy(COVER_X + cover_display_width, COVER_Y),
            xy(COVER_X + cover_display_width, COVER_Y + cover_display_height),
            xy(COVER_X                      , COVER_Y + cover_display_height),
        );

        Simp.immediate_flush();
    }

    text_center_x  := (window_width - 100) / 2;
    y := cast(s64)(COVER_Y + cover_display_width + 100);
    text_padding_y :: 5;

    {
        artist_name_width := Simp.prepare_text(font, album.artist_name);
        artist_name_x := text_center_x - artist_name_width / 2;
        Simp.draw_prepared_text(font, cast(s64)artist_name_x, y, rgba(1,1,1,1));
    }

    y -= text_padding_y + font.character_height;

    {
        album_name_width := Simp.prepare_text(font, album.name);
        album_name_x := text_center_x - album_name_width / 2;
        Simp.draw_prepared_text(font, album_name_x, y, rgba(1,1,1,1));
    }

    y = window_height * 2 / 3 - font.character_height / 4;

    for song: album.songs {

        width := Simp.prepare_text(font, tprint("% - %", song.track, song.name));
        x := window_width / 2;
        if it_index == album_cursor.position {
            Simp.immediate_begin();
            Simp.set_shader_for_color();
            Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + 500, cast(float)y + font.character_height, rgba(1,1,1,1));
            Simp.immediate_flush();
            Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
        } else {
            Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));
        }
        y -= text_padding_y + font.character_height;
    }
}
