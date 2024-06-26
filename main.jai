APPLICATION_NAME :: "bbmp";
#run (#import "Compiler").set_build_options_dc(.{output_executable_name = APPLICATION_NAME});

#scope_file

#import "Basic"()(MEMORY_DEBUGGER=DEBUG_BUILD);
#import "File";
#import "Hash_Table";
#import "Math";
#import "Pool";
#import "String";
#import "Window_Creation";

Process :: #import "Process";
Input   :: #import "Input";
Simp    :: #import "Simp";
MPD     :: #import "libmpdclient";

Now_Playing   :: #import "now_playing";
Library       :: #import "library";
Queue         :: #import "queue";
Album_Art     :: #import "album_art";
Playlist      :: #import "playlist";
Log_View      :: #import "log_view";
Config_Editor :: #import "config_editor";

#import "common";
#import "config";

log_data :: Log_Data.{"main", false};

#scope_module

View :: enum {
    NOW_PLAYING;
    QUEUE;
    ALBUM_ART;
    LIBRARY;
    PLAYLIST;
    CONFIG_EDITOR;
    LOG;
}

current_view := View.ALBUM_ART;

#load "album_art_creation_and_loading.jai";

window: Window_Type;

LONG         : s32 : 0x200000;
TCP_NODELAY  : s32 : LONG + xx 121;

window_width  : s32 = 1920;
window_height : s32 = 1080;

frame: u64 = 0;
frame_rate: float64;
TARGET_FPS :: 30;

show_view_titles := false;
user_input_active := false;

main :: () {
    init_logger();
    context.logger      = logger;
    context.logger_data = *log_data;

    reserve_log_history(100); // default log history in case we need to log config errors

    success: bool;
    config, success = load_config();
    if !success {
        log("Failed to load config, using default.", flags=.WARNING);
    }
    reset_temporary_storage();

    context.log_level = config.log_level;
    reserve_log_history(config.max_log_size);

    init_fonts();

    // TARGET_MSAA_SAMPLE_COUNT :: 16;
    TARGET_MSAA_SAMPLE_COUNT :: 4;
    window = create_window(window_width, window_height, APPLICATION_NAME, wanted_msaa=TARGET_MSAA_SAMPLE_COUNT);
    window_width, window_height = Simp.get_render_dimensions(window);

    Simp.set_render_target(window);

    X_MARGIN_SIZE = window_width / 30;
    Y_MARGIN_SIZE = window_height / 25;
    thumbnail_slot_width  = cast(s32) max(MIN_THUMBNAIL_DISPLAY_WIDTH, window_width / 15);
    thumbnail_slot_height = thumbnail_slot_width;

    mpd_connection = MPD.connection_new(temp_c_string(config.mpd_host), config.mpd_port, 15000);
    if !mpd_connection {
        log("Failed to connect to MPD instance at %:% (out of memory)", config.mpd_host, config.mpd_port, flags=.ERROR);
    }
    handle_errors(tprint("Initializing connection MPD server at %:%", config.mpd_host, config.mpd_port));

    library: Library_Data;
    queue: *Queue.Data;
    albums_sorted_by_artist_and_year: [] *Album;
    playlists: Playlist.Data;

    music_library_pool: Pool;
    #if DEBUG_BUILD  music_library_pool.overwrite_memory = true;

    load_context := context;
    load_context.allocator.proc = pool_allocator_proc;
    load_context.allocator.data = *music_library_pool;

    set_allocators(*music_library_pool);

    load_everything :: () #expand {
        push_context load_context {
            `library                          = Library.load(mpd_connection);
            `queue                            = Queue.load(mpd_connection, library);
            `albums_sorted_by_artist_and_year = Album_Art.load(library);
            `playlists                        = Playlist.load(library);
            Config_Editor.load();
            // start_album_art_creation_on_main_thread(`albums_sorted_by_artist_and_year);
        }
        start_album_art_creation_thread_group(`albums_sorted_by_artist_and_year);
        #if DEBUG_BUILD {
            log("vvvvvvvvvvvvvvv MEMORY REPORT vvvvvvvvvvvvvvv\n");
            log_leak_report(make_leak_report());
            log("^^^^^^^^^^^^^^^ MEMORY REPORT ^^^^^^^^^^^^^^^\n");
        }
    }
    reload_everything :: () #expand {
        MPD.run_update(mpd_connection, null);

        reset(*`music_library_pool);
        load_everything();

        #if DEBUG_BUILD {
            log("vvvvvvvvvvvvvvv MEMORY REPORT vvvvvvvvvvvvvvv\n");
            log_leak_report(make_leak_report());
            log("^^^^^^^^^^^^^^^ MEMORY REPORT ^^^^^^^^^^^^^^^\n");
        }
    }

    load_everything();

    frame: u64 = 0;

    last_global_key_pressed: Key;

    reset_temporary_storage();

    // only keys that repeat when held go in this table
    global_key_pressed_on_frame: Table(Key, u64);
    table_add(*global_key_pressed_on_frame, .B,                   0);
    table_add(*global_key_pressed_on_frame, .F,                   0);
    table_add(*global_key_pressed_on_frame, .LEFT_ANGLE_BRACKET,  0);
    table_add(*global_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, 0);
    table_add(*global_key_pressed_on_frame, .EQUALS_SIGN,         0);
    table_add(*global_key_pressed_on_frame, .DASH,                0);

    while program_loop := true {
        context.logger_data = *log_data;

        frame_start := current_time();

        if queue && current_time() > status_update_timer + 500 {
            Queue.update(mpd_connection, library, queue);
            update_status(Queue.get_current_song(mpd_connection, queue));
        }

        check_album_art_creation_jobs();

        Input.update_window_events();
        for Input.get_window_resizes() {
            Simp.update_window(it.window);
            if it.window == window {
                if (it.width != window_width) || (it.height != window_height) {
                    window_width  = it.width;
                    window_height = it.height;
                    X_MARGIN_SIZE = window_width / 30;
                    Y_MARGIN_SIZE = window_height / 25;
                    ALBUM_ART_DISPLAY_WIDTH = max(MIN_ALBUM_ART_DISPLAY_WIDTH, window_width / 3);
                    thumbnail_slot_width  = cast(s32) max(MIN_THUMBNAIL_DISPLAY_WIDTH, window_width / 15);
                    thumbnail_slot_height = thumbnail_slot_width;
                    init_fonts();
                    // if ENABLE_MSAA  msaa.init(*msaa, window_width, window_height);
                    break;
                }
            }
        }

        seek :: ($seconds: float32) #expand {
            MPD.run_seek_current(mpd_connection, seconds, true);
            handle_errors("Seeking");
            Queue.update(mpd_connection, library, queue);
            update_status_time();
        }
        SEEK_SECONDS :: 0.5;
        // seek_forward  :: (seconds: float = SEEK_SECONDS) #expand { seek(+1 * seconds); }
        // seek_backward :: (seconds: float = SEEK_SECONDS) #expand { seek(-2.5 * seconds); } // TODO: this is too slow on some machines
        seek_forward  :: (seconds: float = SEEK_SECONDS) #expand { seek(- (5.0 / TARGET_FPS) + 5 * seconds); }
        seek_backward :: (seconds: float = SEEK_SECONDS) #expand { seek(- (5.0 / TARGET_FPS) - 5 * seconds); }

        play_previous_song :: () #expand {
            last_global_key_pressed = .LEFT_ANGLE_BRACKET;
            MPD.run_previous(mpd_connection);
            handle_errors("Playing previous song");
            update_status(Queue.get_current_song(mpd_connection, queue));
        }
        play_next_song :: () #expand {
            MPD.run_next(mpd_connection);
            handle_errors("Playing next song");
            update_status(Queue.get_current_song(mpd_connection, queue));
        }

        change_volume :: ($amount: s32) #expand {
            MPD.run_change_volume(mpd_connection, amount);
            handle_errors("Changing volume");
            update_status(Queue.get_current_song(mpd_connection, queue));
        }
        VOLUME_CHANGE_AMOUNT :: 2;
        increment_volume :: () #expand { change_volume( VOLUME_CHANGE_AMOUNT); }
        decrement_volume :: () #expand { change_volume(-VOLUME_CHANGE_AMOUNT); }

        for Input.events_this_frame {
            if it.type == .QUIT {
                break program_loop;
            }
            if !user_input_active && it.type == .KEYBOARD && it.key_pressed {
                if it.ctrl_pressed {
                    if it.key_code == {

                      case KEY_T; // CTRL_t
                        show_view_titles = !show_view_titles;;

                      case KEY_C;
                        MPD.run_clear(mpd_connection);
                        handle_errors("Clearing queue");
                        Queue.update(mpd_connection, library, queue);
                        update_status(Queue.get_current_song(mpd_connection, queue));
                        break it;

                    }
                } else {
                    if it.key_code == {

                      case KEY_Q;
                        if it.shift_pressed {
                            break program_loop;
                        }

                      case .NUMBER_1;
                        current_view = .NOW_PLAYING;
                        break it;
                      case .NUMBER_2;
                        current_view = .QUEUE;
                        Queue.update(mpd_connection, library, queue);
                        break it;
                      case .NUMBER_3;
                        current_view = .ALBUM_ART;
                        break it;
                      case .NUMBER_4;
                        current_view = .LIBRARY;
                        break it;
                      case .NUMBER_5;
                        current_view = .PLAYLIST;
                        break it;
                      case .NUMBER_6;
                        current_view = .CONFIG_EDITOR;
                        break it;
                      case .NUMBER_7;
                        current_view = .LOG;
                        break it;

                      case KEY_R;
                        if it.shift_pressed {
                            reload_everything();
                            break it;
                        }

                      case KEY_P;
                        MPD.run_toggle_pause(mpd_connection);
                        handle_errors("Toggling pause");
                        break it;

                      case KEY_B;
                        last_global_key_pressed = .B;
                        table_set(*global_key_pressed_on_frame, .B, frame);
                        seek_backward();
                        break it;
                      case KEY_F;
                        if !it.shift_pressed {
                            last_global_key_pressed = .F;
                            table_set(*global_key_pressed_on_frame, .F, frame);
                            seek_forward();
                            break it;
                        }

                      case .LEFT_ANGLE_BRACKET;
                        if it.shift_pressed {
                            last_global_key_pressed = .LEFT_ANGLE_BRACKET;
                            table_set(*global_key_pressed_on_frame, .LEFT_ANGLE_BRACKET, frame);
                            play_previous_song();
                            break it;
                        }
                      case .RIGHT_ANGLE_BRACKET;
                        if it.shift_pressed {
                            last_global_key_pressed = .RIGHT_ANGLE_BRACKET;
                            table_set(*global_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, frame);
                            play_next_song();
                            break it;
                        }

                      case .EQUALS_SIGN;
                        last_global_key_pressed = .EQUALS_SIGN;
                        table_set(*global_key_pressed_on_frame, .EQUALS_SIGN, frame);
                        increment_volume();
                        break it;
                      case .DASH;
                        last_global_key_pressed = .DASH;
                        table_set(*global_key_pressed_on_frame, .DASH, frame);
                        decrement_volume();
                        break it;

                    }
                }
            }
        }

        if !user_input_active {
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .B, threshold=8*KEY_HOLD_DELAY) seek_backward(6*SEEK_SECONDS);
            else
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .B, threshold=6*KEY_HOLD_DELAY) seek_backward(4*SEEK_SECONDS);
            else
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .B, threshold=4*KEY_HOLD_DELAY) seek_backward(2*SEEK_SECONDS);
            else
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .B)                             seek_backward();

            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .F, threshold=8*KEY_HOLD_DELAY) seek_forward(6*SEEK_SECONDS);
            else
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .F, threshold=6*KEY_HOLD_DELAY) seek_forward(4*SEEK_SECONDS);
            else
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .F, threshold=4*KEY_HOLD_DELAY) seek_forward(2*SEEK_SECONDS);
            else
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .F)                             seek_forward();

            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .LEFT_ANGLE_BRACKET)  play_previous_song();
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .RIGHT_ANGLE_BRACKET) play_next_song();
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .EQUALS_SIGN)         increment_volume();
            if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .DASH)                decrement_volume();
        }

        Simp.clear_render_target(0,0,0,1);

        header_boundary := view_boundary(
            top    = window_height - Y_MARGIN_SIZE,
            bottom = Y_MARGIN_SIZE,
            left   = X_MARGIN_SIZE,
            right  = window_width - X_MARGIN_SIZE,
        );
        header_bottom := draw_header(header_boundary);

        boundary := view_boundary(
            top    = header_bottom - Y_MARGIN_SIZE,
            bottom = Y_MARGIN_SIZE,
            left   = X_MARGIN_SIZE,
            right  = window_width - X_MARGIN_SIZE,
        );
        if current_view == {
          case .NOW_PLAYING;
            Now_Playing.event_loop(albums_sorted_by_artist_and_year, boundary);
          case .QUEUE;
            user_input_active = Queue.event_loop(mpd_connection, library, queue, frame, boundary);
          case .ALBUM_ART;
            user_input_active = Album_Art.event_loop(mpd_connection, albums_sorted_by_artist_and_year, library, queue, frame, boundary);
          case .LIBRARY;
            user_input_active = Library.event_loop(mpd_connection, library, queue, frame, boundary);
          case .PLAYLIST;
            user_input_active = Playlist.event_loop(mpd_connection, playlists, library, queue, frame, boundary);
          case .LOG;
            Log_View.event_loop(frame, boundary);
          case .CONFIG_EDITOR;
            user_input_active = Config_Editor.event_loop(frame, boundary);
        }
        reset_temporary_storage();
        Simp.swap_buffers(window);

        // memory_visualizer_per_frame_update();

        frame += 1;

        calculate_frame_rate :: (start: u64, end: u64) -> float64 {
            return 1000000.0 / (end - start);
        }

        frame_rate = calculate_frame_rate(frame_start, current_time());
        frame_time_ms := 1000 / frame_rate;
        MAX_MS_PER_FRAME :: 1000.0 / TARGET_FPS;
        if frame_time_ms < MAX_MS_PER_FRAME {
            sleep_milliseconds(cast(s32) (MAX_MS_PER_FRAME - frame_time_ms));
        }
        frame_end := current_time();
        frame_rate = calculate_frame_rate(frame_start, current_time());
        if !(frame % TARGET_FPS) {
            log("frame rate: % fps (% ms / frame)", frame_rate, 1000.0 / frame_rate, flags=.VERBOSE_ONLY);
        }
    }

    MPD.connection_free(mpd_connection);
}

draw_header :: (boundary: View_Boundary) -> int {
    font := fonts.regular;
    header_bottom := boundary.top; // just initting this

    { // current / total track time
        x := boundary.left;
        y := boundary.top - line_height / 2;
        Simp.draw_text(
            font,
            x,
            y,
            tprint(
                "%/%",
                seconds_to_time_string(status.elapsed_time),
                seconds_to_time_string(status.total_time)
            ),
            rgba(1,1,1,1),
        );
    }

    if mpd_connection { // currently playing song + artist/album
        x := boundary.left + boundary.width / 2;
        y := boundary.top;

        max_characters_in_column := (boundary.width / 2) / font.w_width;
        if status.song {
            text_width := Simp.prepare_text(fonts.regular, slice(status.song, 0, max_characters_in_column));
            Simp.draw_prepared_text(fonts.regular, x - text_width / 2, y, rgba(1,1,1,1));
        }
        y -= font.character_height + TEXT_PADDING_Y;

        if status.artist || status.album {
            text_width := Simp.prepare_text(fonts.regular, slice(tprint("% - %", status.artist, status.album), 0, max_characters_in_column));
            Simp.draw_prepared_text(fonts.regular, x - text_width / 2, y, rgba(1,1,1,1));
        }
        y -= font.character_height;

        header_bottom = y;
    } else {
        x := cast(int)window_width / 2;
        y := boundary.top - line_height / 2;
        msg :: "Not connected to MPD -- please ensure your config is pointing to a valid MPD server and restart.";

        text_width := Simp.prepare_text(font, msg);
        Simp.draw_prepared_text(
            font,
            x - text_width / 2,
            y,
            rgba(1,0,0,1),
        );
        y -= font.character_height;

        header_bottom = y;
    }

    { // volume
        x := boundary.right - font.w_width * 10;
        y := boundary.top - line_height / 2;
        display_volume := ifx status.volume >= 0 then tprint("%1%%", left_pad(status.volume, #char " ", 3)) else "N/A";

        Simp.draw_text(
            fonts.regular,
            x,
            y,
            tprint("Vol: %", display_volume),
            rgba(1,1,1,1),
        );
    }

    if show_view_titles {
        x_padding_between_view_titles : s64 = fonts.regular.character_height;
        VIEW_TITLES :: string.["Now Playing", "Queue", "Library Album Art", "Library", "Playlists", "Config Viewer", "Debug Logs"];
        x := boundary.left;
        y := header_bottom - line_height;
        for title: VIEW_TITLES {
            text_width := Simp.prepare_text(font, tprint("(%) %", it_index + 1, title));

            selected := cast(s64)current_view == it_index;
            if selected {
                x0 := cast(float)x - x_padding_between_view_titles / 3;
                y0, y1 := get_highlight_y_range(font, y);
                highlight_width  := text_width + x_padding_between_view_titles;
                highlight_height := font.character_height + TEXT_PADDING_Y;

                Simp.set_shader_for_color();
                Simp.immediate_quad(
                    x0,
                    y0,
                    x0 + highlight_width,
                    y0 + highlight_height,
                    rgba(0.85,0.85,0.85,1),
                );
                // Simp.immediate_quad(cast(float)x - 5, cast(float)y - 5, cast(float)x + text_width + 5, cast(float)y + font.height, rgba(0.85,0.85,0.85,1));
                Simp.draw_prepared_text(font, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(fonts.regular, x, y, rgba(1,1,1,1));
            }
            x += text_width + x_padding_between_view_titles;
        }
        header_bottom -= line_height;
    }

    // some additional padding
    // header_bottom -= Y_MARGIN_SIZE * 2;

    return header_bottom;
}

init_fonts :: () {
    #import "freetype-2.12.1";

    load_font_data :: (filename: string) -> []u8 {
        s, success := read_entire_file(filename);
        assert(success, "Failed to load font file at %", filename);
        return cast([]u8) s;
    }

    FT_ROUND :: inline (x: int) -> int {
        if x >= 0 return (x + 0x1f) >> 6;
        return -(((-x) + 0x1f) >> 6);
    }

    pixel_height := window_height / (ifx window_height > 1080 then 96 else 72);
    // log("pixel_height: %", pixel_height);

    // better size for streaming
    // pixel_height := window_height / 56;

    fonts.regular = New(Font);
    {
        font := fonts.regular;
        font_data : [] u8 = #run load_font_data("./fonts/Inconsolata-Regular.ttf"); // load font at compile time
        font.base = Simp.get_font_at_size(font_data, pixel_height);

        font.max_font_height = cast(float)font.typical_ascender - font.typical_descender; // typical_descender is negative (# of pixels below line in a letter like 'g')

        font_face := font.private1;
        glyph_index := FT_Get_Char_Index(font_face, #char "W");
        if glyph_index {
            FT_Load_Glyph(font_face, glyph_index, FT_LOAD_DEFAULT);
            font.w_width = FT_ROUND(font_face.glyph.metrics.width);
        }

        line_height = font.default_line_spacing + TEXT_PADDING_Y; // this values seems fine, but we could have more control with e.g. font.max_height + <some padding value>
    }
    assert(fonts.regular != null);

    fonts.bold = New(Font);
    {
        font := fonts.bold;
        font_data : [] u8 = #run load_font_data("./fonts/Inconsolata-Bold.ttf"); // load font at compile time
        font.base = Simp.get_font_at_size(font_data, pixel_height);

        font.max_font_height = cast(float)font.typical_ascender - font.typical_descender;

        font_face := font.private1;
        glyph_index := FT_Get_Char_Index(font_face, #char "W");
        if glyph_index {
            FT_Load_Glyph(font_face, glyph_index, FT_LOAD_DEFAULT);
            font.w_width = FT_ROUND(font_face.glyph.metrics.width);
        }

        // this shouldn't change from above, just a mild precaution
        line_height = max(line_height, font.default_line_spacing + TEXT_PADDING_Y);
    }
    assert(fonts.bold != null);
}
