APPLICATION_NAME :: "bbmp";
#run (#import "Compiler").set_build_options_dc(.{output_executable_name = APPLICATION_NAME});

ENABLE_MSAA :: true;

#scope_file

#import "Basic"()(MEMORY_DEBUGGER=false);
#import "File";
#import "Math";
#import "String";
#import "Window_Creation";

Process :: #import "Process";
Input   :: #import "Input";
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

msaa: OpenGL_MSAA;

// this MSAA implementation is entirely thanks to @cart in the jai beta
OpenGL_MSAA :: struct {
  #import "GL";

  fbo, tex, rbo: GLuint;
  msaa_samples: GLuint = 16;
  initialized := false;

  window_width, window_height: s32;

  // Call after Simp.set_render_target, and whenever the window size changes.
  init :: (using msaa: *OpenGL_MSAA, width: s32, height: s32) {
    if initialized  deinit(msaa);

    window_width = width;
    window_height = height;

    glGenFramebuffers(1, *fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);

    glGenTextures(1, *tex);
   glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, tex);
    glTexImage2DMultisample(GL_TEXTURE_2D_MULTISAMPLE, msaa_samples, GL_RGB, xx window_width, xx window_height, GL_TRUE);
    glTexParameteri(GL_TEXTURE_2D_MULTISAMPLE, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_MULTISAMPLE, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_MULTISAMPLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_MULTISAMPLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D_MULTISAMPLE, tex, 0);

    glGenRenderbuffers(1, *rbo);
    glBindRenderbuffer(GL_RENDERBUFFER, rbo);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, msaa_samples, GL_DEPTH24_STENCIL8, xx window_width, xx window_height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rbo);

    fbo_status := glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if fbo_status != GL_FRAMEBUFFER_COMPLETE {
      print("Error: Framebuffer status = %\n", fbo_status);
      return;
    }

    initialized = true;
  }

  deinit :: (using msaa: *OpenGL_MSAA) {
    glDeleteFramebuffers(1, *fbo);
  }

  // Call at the start of each frame
  start_drawing :: (using msaa: *OpenGL_MSAA) {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  }

  // Call before swap_buffers
  finish_drawing :: (using msaa: *OpenGL_MSAA) {
    // Bind the MSAA and postprocessing framebuffers as read and draw
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glBlitFramebuffer(0, 0, xx window_width, xx window_height,
                      0, 0, xx window_width, xx window_height,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
  }
}

// share Simp with album art management file -- is this necessary?
Simp :: #import "Simp";

View :: enum {
    NOW_PLAYING;
    QUEUE;
    ALBUM_ART;
    LIBRARY;
    PLAYLIST;
    CONFIG_EDITOR;
    LOG;
}

current_view := View.LIBRARY;

#load "album_art_creation_and_loading.jai";

window: Window_Type;

LONG         : s32 : 0x200000;
TCP_NODELAY  : s32 : LONG + xx 121;

thumbnail_slot_width  : s32 = 200;
thumbnail_slot_height : s32 = 200;

window_width  : s32 = 1920;
window_height : s32 = 1080;

display_width :: inline () -> int { return window_width - 2 * X_MARGIN_SIZE; }

frame: u64 = 0;
frame_rate: float64;
TARGET_FPS :: 30;

hide_view_titles := false;
user_input_active := false;

main :: () {

    context.logger      = logger;
    context.logger_data = *log_data;

    reserve_log_history(1000); // default log history in case we need to log config errors

    success: bool;
    config, success = load_config();
    if !success {
        log("Failed to load config, using default.", flags=.WARNING);
    }
    reset_temporary_storage();

    reserve_log_history(config.max_log_size);

    init_fonts();

    window = create_window(window_width, window_height, APPLICATION_NAME);
    window_width, window_height = Simp.get_render_dimensions(window);

    Simp.set_render_target(window);
    #if ENABLE_MSAA  {
      msaa.init(*msaa, window_width, window_height);
      defer msaa.deinit(*msaa);
    }

    X_MARGIN_SIZE = window_width / 30;
    Y_MARGIN_SIZE = window_height / 25;
    Y_PADDING_BELOW_HEADER = Y_MARGIN_SIZE * 2;
    thumbnail_slot_width  = cast(s32) max(MIN_THUMBNAIL_DISPLAY_WIDTH, window_width / 15);
    thumbnail_slot_height = thumbnail_slot_width;

    mpd_connection = MPD.connection_new(temp_c_string(config.mpd_host), config.mpd_port, 15000);
    if !mpd_connection {
        log("Failed to connect to MPD instance at %:% (out of memory)", config.mpd_host, config.mpd_port, flags=.ERROR);
    }
    handle_errors(tprint("Initializing connection MPD server at %:%", config.mpd_host, config.mpd_port));

    library                          := Library.load(mpd_connection);
    queue                            := Queue.load(mpd_connection, library);
    albums_sorted_by_artist_and_year := Album_Art.load(library);
    playlists                        := Playlist.load(library);
    Config_Editor.load();

    start_album_art_creation_thread_group(albums_sorted_by_artist_and_year);

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
                    if ENABLE_MSAA  msaa.init(*msaa, window_width, window_height);
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
                    }
                    break it;

                  case .LEFT_ANGLE_BRACKET;
                    if it.shift_pressed {
                        last_global_key_pressed = .LEFT_ANGLE_BRACKET;
                        table_set(*global_key_pressed_on_frame, .LEFT_ANGLE_BRACKET, frame);
                        play_previous_song();
                    }
                    break it;
                  case .RIGHT_ANGLE_BRACKET;
                    if it.shift_pressed {
                        last_global_key_pressed = .RIGHT_ANGLE_BRACKET;
                        table_set(*global_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, frame);
                        play_next_song();
                    }
                    break it;

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

                  case KEY_C;
                    MPD.run_clear(mpd_connection);
                    handle_errors("Clearing queue");
                    Queue.update(mpd_connection, library, queue);
                    update_status(Queue.get_current_song(mpd_connection, queue));
                    break it;

                  case KEY_H; // CTRL_h
                    if !(Input.input_button_states[Input.Key_Code.CTRL] & .DOWN) break it;
                    hide_view_titles = !hide_view_titles;;
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

        #if ENABLE_MSAA  msaa.start_drawing(*msaa);
        Simp.clear_render_target(0,0,0,1);
        header_bottom := draw_header();
        if current_view == {
          case .NOW_PLAYING;
            Now_Playing.event_loop(albums_sorted_by_artist_and_year, window_width, header_bottom);
          case .QUEUE;
            user_input_active = Queue.event_loop(mpd_connection, library, queue, frame, fonts, cast(s32)display_width(), header_bottom);
          case .ALBUM_ART;
            user_input_active = Album_Art.event_loop(mpd_connection, albums_sorted_by_artist_and_year, library, queue, frame, fonts, cast(s32)display_width(), header_bottom, thumbnail_slot_width, thumbnail_slot_height);
          case .LIBRARY;
            user_input_active = Library.event_loop(mpd_connection, library, queue, frame, fonts, cast(s32)display_width(), header_bottom);
          case .PLAYLIST;
            user_input_active = Playlist.event_loop(mpd_connection, playlists, library, queue, frame, fonts, cast(s32)display_width(), header_bottom);
          case .LOG;
            Log_View.event_loop(fonts.regular, frame, cast(s32)display_width(), header_bottom);
          case .CONFIG_EDITOR;
            user_input_active = Config_Editor.event_loop(fonts.regular, frame, cast(s32)display_width(), header_bottom);
        }
        reset_temporary_storage();
        #if ENABLE_MSAA  msaa.finish_drawing(*msaa);
        Simp.swap_buffers(window);

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

draw_header :: () -> int {

    top := cast(int)window_height - Y_MARGIN_SIZE;
    header_bottom := top;

    { // current / total track time
        x := X_MARGIN_SIZE;
        y := top - TEXT_PADDING_Y - fonts.regular.character_height / 2;
        Simp.draw_text(
            fonts.regular,
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
        x := cast(int)window_width / 2;
        y := top;

        max_characters_in_column := (display_width() / 2) / fonts.regular.w_width;
        if status.song {
            text_width := Simp.prepare_text(fonts.regular, slice(status.song, 0, max_characters_in_column));
            Simp.draw_prepared_text(fonts.regular, x - text_width / 2, y, rgba(1,1,1,1));
        }
        y -= TEXT_PADDING_Y + fonts.regular.character_height;

        if status.artist || status.album {
            text_width := Simp.prepare_text(fonts.regular, slice(tprint("% - %", status.artist, status.album), 0, max_characters_in_column));
            Simp.draw_prepared_text(fonts.regular, x - text_width / 2, y, rgba(1,1,1,1));
        }

        header_bottom = y - fonts.regular.character_height;
    } else {
        x := cast(int)window_width / 2;
        y := top - TEXT_PADDING_Y - fonts.regular.character_height / 2;
        msg :: "Not connected to MPD -- please ensure your config is pointing to a valid MPD server and restart.";
        text_width := Simp.prepare_text(fonts.regular, msg);
        Simp.draw_prepared_text(
            fonts.regular,
            x - text_width / 2,
            y,
            rgba(1,0,0,1),
        );
        header_bottom = y - fonts.regular.character_height;
    }

    { // volume
        x := display_width() + X_MARGIN_SIZE - fonts.regular.w_width * 10;
        y := top - TEXT_PADDING_Y - fonts.regular.character_height / 2;
        display_volume := ifx status.volume >= 0 then tprint("%1%%", left_pad(status.volume, #char " ", 3)) else "N/A";
        Simp.draw_text(
            fonts.regular,
            x,
            y,
            tprint("Vol: %", display_volume),
            rgba(1,1,1,1),
        );
    }

    if !hide_view_titles {
        VIEW_TITLES :: string.["Now Playing", "Queue", "Library Album Art", "Library", "Playlists", "Config Viewer", "Debug Logs"];
        x := cast(s64)X_MARGIN_SIZE;
        y := header_bottom - Y_MARGIN_SIZE;
        for title: VIEW_TITLES {
            text_width := Simp.prepare_text(fonts.regular, tprint("(%) %", it_index + 1, title));
            selected := cast(s64)current_view == it_index;
            if selected {
                Simp.set_shader_for_color();
                Simp.immediate_quad(cast(float)x - 5, cast(float)y - 5, cast(float)x + text_width + 5, cast(float)y + fonts.regular.character_height, rgba(0.85,0.85,0.85,1));
                Simp.draw_prepared_text(fonts.regular, x, y, rgba(0,0,0,1));
            } else {
                Simp.draw_prepared_text(fonts.regular, x, y, rgba(1,1,1,1));
            }
            x += text_width + X_PADDING_BETWEEN_VIEW_TITLES;
        }
        header_bottom -= Y_MARGIN_SIZE + fonts.regular.character_height;
    }

    header_bottom -= Y_PADDING_BELOW_HEADER;

    return header_bottom;
}

fonts: Fonts;
init_fonts :: () {

    load_font_data :: (filename: string) -> []u8 {
        s, success := read_entire_file(filename);
        assert(success, "Failed to load font file at %", filename);
        return cast([]u8) s;
    }

    pixel_height := window_height / (ifx window_height > 1080 then 96 else 72);
    // better size for streaming
    // pixel_height := window_height / 56;

    font_data : [] u8 = #run load_font_data("./fonts/Inconsolata-Regular.ttf"); // load font at compile time
    fonts.regular = Simp.get_font_at_size(font_data, pixel_height);
    assert(fonts.regular != null);

    bold_font_data : [] u8 = #run load_font_data("./fonts/Inconsolata-Bold.ttf");
    fonts.bold = Simp.get_font_at_size(bold_font_data, pixel_height);
    assert(fonts.bold != null);
}
