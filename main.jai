#import "Basic"()(MEMORY_DEBUGGER=false);
#import "Math";
#import "String";
#import "Window_Creation";
#import "Time";

#run (#import "Compiler").set_output_executable_name("grishcompoop");

Process :: #import "Process";
Simp    :: #import "Simp";
Input   :: #import "Input";
MPD     :: #import "libmpdclient";

#load "queue.jai";
#load "library.jai";
#load "library_album_art.jai";
#load "threaded_album_art_creation.jai";
#load "common.jai";

window: Window_Type;

Screen :: enum {
    QUEUE;
    LIBRARY;
    LIBRARY_ALBUM_ART;
}

current_screen := Screen.LIBRARY;

LONG         : s32 : 0x200000;
TCP_NODELAY  : s32 : LONG + xx 121;

mpd_connection: *MPD.connection;

window_width  : s32 = 1920;
window_height : s32 = 1080;

display_width  :: () -> int #expand { return window_width  - 2 * X_MARGIN_SIZE; }
// display_height :: () -> int #expand { return window_height - 2 * Y_MARGIN_SIZE; }

frame: u64 = 0;
frame_rate: float64;
TARGET_FPS :: 30;

main :: () {

    init_fonts();

    window = create_window(window_width, window_height, "ncmpjai");
    window_width, window_height = Simp.get_render_dimensions(window);

    Simp.set_render_target(window);
    X_MARGIN_SIZE = window_width / 30;
    Y_MARGIN_SIZE = window_height / 30;
    THUMBNAIL_SLOT_WIDTH  = cast(s32) max(MIN_THUMBNAIL_DISPLAY_WIDTH, window_width / 10);
    THUMBNAIL_SLOT_HEIGHT = THUMBNAIL_SLOT_WIDTH;

    mpd_connection = MPD.connection_new(null, 0, 15000);
    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors("Initializing MPD connection");

    load_library();
    load_queue();
    load_library_album_art();
    start_album_art_creation_thread_group(); // this must be called AFTER load_library() and load_library_album_art()

    library_init_repeatable_keys();
    queue_init_repeatable_keys();
    library_album_art_init_repeatable_keys();
    album_init_repeatable_keys();

    quit := false;
    frame: u64 = 0;

    last_global_key_pressed: Key;

    // only keys that repeat when held go in this table
    global_key_pressed_on_frame: Table(Key, u64);
    table_add(*global_key_pressed_on_frame, .B,                   0);
    table_add(*global_key_pressed_on_frame, .F,                   0);
    table_add(*global_key_pressed_on_frame, .LEFT_ANGLE_BRACKET,  0);
    table_add(*global_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, 0);
    table_add(*global_key_pressed_on_frame, .EQUALS_SIGN,         0);
    table_add(*global_key_pressed_on_frame, .DASH,                0);

    reset_temporary_storage();

    while !quit {
        if get_current_file_time() > status_update_timer + 10000000 {
            update_status();
        }
        frame_start := get_current_file_time();

        check_album_art_creation_jobs();

        Input.update_window_events();
        for Input.get_window_resizes() {
            Simp.update_window(it.window);
            if it.window == window {
                if (it.width != window_width) || (it.height != window_height) {
                    window_width  = it.width;
                    window_height = it.height;
                    X_MARGIN_SIZE = window_width / 30;
                    Y_MARGIN_SIZE = window_height / 30;
                    ALBUM_ART_DISPLAY_WIDTH = max(MIN_ALBUM_ART_DISPLAY_WIDTH, window_width / 3);
                    THUMBNAIL_SLOT_WIDTH  = cast(s32) max(MIN_THUMBNAIL_DISPLAY_WIDTH, window_width / 10);
                    THUMBNAIL_SLOT_HEIGHT = THUMBNAIL_SLOT_WIDTH;
                    init_fonts();
                    break;
                }
            }
        }

        seek :: ($seconds: float32) #expand {
            MPD.run_seek_current(mpd_connection, seconds, true);
            handle_errors("Seeking");
            update_status_time();
        }
        SEEK_SECONDS :: 0.5;
        seek_forward  :: (seconds: float = SEEK_SECONDS) #expand { seek(seconds);  }
        seek_backward :: (seconds: float = SEEK_SECONDS) #expand { seek(-seconds); }

        play_previous_song :: () #expand {
            last_global_key_pressed = .LEFT_ANGLE_BRACKET;
            MPD.run_previous(mpd_connection);
            handle_errors("Playing previous song");
            update_status(false);
        }
        play_next_song :: () #expand {
            MPD.run_next(mpd_connection);
            handle_errors("Playing next song");
            update_status(false);
        }

        change_volume :: ($amount: s32) #expand {
            MPD.run_change_volume(mpd_connection, amount);
            handle_errors("Changing volume");
            update_status_volume();
        }
        VOLUME_CHANGE_AMOUNT :: 2;
        increment_volume :: () #expand { change_volume( VOLUME_CHANGE_AMOUNT); }
        decrement_volume :: () #expand { change_volume(-VOLUME_CHANGE_AMOUNT); }

        for Input.events_this_frame {
            if it.type == {
              case .QUIT;
                quit = true;
                break;
              case .KEYBOARD;
                if it.key_pressed {
                    if it.key_code == {
                      case KEY_Q;
                        if it.shift_pressed {
                            quit = true;
                            break it;
                        }

                      case .NUMBER_1;
                        current_screen = .QUEUE;
                        load_queue_changes();
                        break it;
                      case .NUMBER_2;
                        current_screen = .LIBRARY;
                        break it;
                      case .NUMBER_3;
                        current_screen = .LIBRARY_ALBUM_ART;
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
                        last_global_key_pressed = .F;
                        table_set(*global_key_pressed_on_frame, .F, frame);
                        seek_forward();
                        break it;

                      case .LEFT_ANGLE_BRACKET;
                        last_global_key_pressed = .LEFT_ANGLE_BRACKET;
                        table_set(*global_key_pressed_on_frame, .LEFT_ANGLE_BRACKET, frame);
                        play_previous_song();
                        break it;
                      case .RIGHT_ANGLE_BRACKET;
                        last_global_key_pressed = .RIGHT_ANGLE_BRACKET;
                        table_set(*global_key_pressed_on_frame, .RIGHT_ANGLE_BRACKET, frame);
                        play_next_song();
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
                        load_queue_changes();
                        update_status();
                        break it;
                    }
                }
            }
        }

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

        Simp.clear_render_target(0,0,0,1);
        header_bottom := draw_header();
        if current_screen == {
          case .QUEUE;
            queue_event_loop(frame, header_bottom);
          case .LIBRARY;
            library_event_loop(frame, header_bottom);
          case .LIBRARY_ALBUM_ART;
            library_album_art_event_loop(frame, header_bottom);
        }
        reset_temporary_storage();
        Simp.swap_buffers(window);

        frame += 1;

        calculate_frame_rate :: (start: u64, end: u64) -> float64 {
            return 10000000.0 / (end - start);
        }

        frame_rate = calculate_frame_rate(frame_start, get_current_file_time());
        frame_time_ms := 1000 / frame_rate;
        MAX_MS_PER_FRAME :: 1000.0 / TARGET_FPS;
        if frame_time_ms < MAX_MS_PER_FRAME {
            sleep_milliseconds(cast(s32) (MAX_MS_PER_FRAME - frame_time_ms));
        }
        frame_rate = calculate_frame_rate(frame_start, get_current_file_time());
        if !(frame % TARGET_FPS) {
            print("frame rate: %\n", frame_rate);
        }
    }

    MPD.connection_free(mpd_connection);
}

/******************
* status bar info *
******************/

Status :: struct {
    artist:       string;
    album:        string;
    song:         string;
    elapsed_time: u32;
    total_time:   u32;
    volume:       s32;
}

status: Status;

status_update_timer: u64 = 0;
update_status :: (update_queue := true) {
    status_update_timer = get_current_file_time();

    mpd_status := MPD.run_status(mpd_connection);
    handle_errors("Retrieving MPD status");
    MPD.response_finish(mpd_connection);

    if update_queue load_queue_changes();
    queue_song_position := MPD.status_get_song_pos(mpd_status);
    if queue_song_position >= 0 {
        song := queue.songs[queue_song_position];
        status.artist = copy_string(song.artist);
        status.album  = copy_string(song.album);
        status.song   = copy_string(song.name);
    } else {
        status.artist = "";
        status.album  = "";
        status.song   = "";
    }
    status.elapsed_time = MPD.status_get_elapsed_time(mpd_status);
    status.total_time   = MPD.status_get_total_time(mpd_status);
    status.volume       = MPD.status_get_volume(mpd_status);
    MPD.status_free(mpd_status);
}

update_status_volume :: () {
    mpd_status := MPD.run_status(mpd_connection);
    handle_errors("Retrieving MPD status");
    MPD.response_finish(mpd_connection);
    status.volume       = MPD.status_get_volume(mpd_status);
    MPD.status_free(mpd_status);
}

update_status_time :: () {
    mpd_status := MPD.run_status(mpd_connection);
    handle_errors("Retrieving MPD status");
    MPD.response_finish(mpd_connection);
    status.elapsed_time = MPD.status_get_elapsed_time(mpd_status);
    status.total_time   = MPD.status_get_total_time(mpd_status);
    MPD.status_free(mpd_status);
}

draw_header :: () -> int {

    top := cast(int)window_height - 2 * Y_MARGIN_SIZE;

    header_bottom := top;

    { // current track time
        x := X_MARGIN_SIZE;
        y := top - TEXT_PADDING_Y - font.character_height / 2;
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

        header_bottom = min(header_bottom, y - font.character_height);
    }

    { // currently playing song + artist/album
        x := cast(int)window_width / 2;
        y := top;

        max_characters_in_column := (display_width() / 2) / font.w_width;
        if status.song {
            text_width := Simp.prepare_text(font, slice(status.song, 0, max_characters_in_column));
            Simp.draw_prepared_text(font, x - text_width / 2, y, rgba(1,1,1,1));
        }
        y -= TEXT_PADDING_Y + font.character_height;

        if status.artist || status.album {
            text_width := Simp.prepare_text(font, slice(tprint("% - %", status.artist, status.album), 0, max_characters_in_column));
            Simp.draw_prepared_text(font, x - text_width / 2, y, rgba(1,1,1,1));
        }

        header_bottom = min(header_bottom, y - font.character_height);
    }

    { // volume
        x := display_width() + X_MARGIN_SIZE - font.w_width * 10;
        y := top - TEXT_PADDING_Y - font.character_height / 2;
        display_volume := ifx status.volume >= 0 then tprint("%1%%", left_pad(status.volume, #char " ", 3)) else "N/A";
        Simp.draw_text(
            font,
            x,
            y,
            tprint("Vol: %", display_volume),
            rgba(1,1,1,1),
        );
        header_bottom = min(header_bottom, y - font.character_height);
    }

    header_bottom -= 25;

    return header_bottom;
}

font, font_bold : *Simp.Dynamic_Font;
init_fonts :: () {

    font_data: [] u8 = ---;
    load_font_data :: (filename: string) -> []u8 {
        s, success := read_entire_file(filename);
        assert(success);
        return cast([]u8) s;
    }
    font_data = #run load_font_data("./Inconsolata-Regular.ttf"); // load font at compile time

    pixel_height := window_height / (ifx window_height > 1080 then 96 else 72);
    // better size for streaming
    // pixel_height := window_height / 56;

    font = Simp.get_font_at_size(font_data, pixel_height);
    assert(font != null);

    // if (font_bold != null) free(font_bold);
    // font_bold = Simp.get_font_at_size("/home/grish/src/jai/jai-mpd", "Inconsolata-SemiBold.ttf", pixel_height);
    // assert(font_bold != null);
}

Error :: struct {
    code: MPD.server_error;
    message: string;
    recovered: bool;
    type: enum { SERVER; CLIENT; };
}

Server_Error :: struct {
    using _error: Error;
    type = .SERVER;
}

Client_Error :: struct {
    using _error: Error;
    type = .CLIENT;
}

// returns true if a reconnect happened, false otherwise
handle_errors :: (message: string) -> bool {

    error := check_connection_errors();
    if error {
        print("%: % error, code=%, message='%', recovered=%\n", message, error.type, error.code, error.message, error.recovered);
        if !error.recovered {
            print("Failed to recover from error, attempting to reconnect to MPD\n");

            MPD.run_clear(mpd_connection);
            mpd_connection = MPD.connection_new(null, 0, 15000);
            if mpd_connection == null {
                print("MPD reconnect failed, might be out of memory. Exiting\n");
                exit(1);
            }

            // TODO: if we get 'connection refused', wait a second before restarting (goes wayy to fast for my laptop)
            new_connection_error := check_connection_errors();
            while new_connection_error {
                MPD.run_clear(mpd_connection);
                mpd_connection = MPD.connection_new(null, 0, 0);
                new_connection_error = check_connection_errors();
                print("Failed to reconnect: % error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
            }

            print("Successfully reconnected to MPD\n");
            return true;
        }
        print("Recovered from error\n");
    }
    return false;
}

check_connection_errors :: () -> *Error {
    error_code := MPD.connection_get_error(mpd_connection);
    if (error_code != .SUCCESS) {
        msg := copy_temp_from_c_string(MPD.connection_get_error_message(mpd_connection));

        if error_code == .SERVER {
            error := New(Server_Error, allocator=__temporary_allocator);
            error.code      = MPD.connection_get_server_error(mpd_connection);
            error.message   = msg;
            error.recovered = MPD.connection_clear_error(mpd_connection);
            return error;
        } else {
            error := New(Client_Error, allocator=__temporary_allocator);
            error.message   = msg;
            error.recovered = MPD.connection_clear_error(mpd_connection);
            return error;
        }
    }

    return null;
}
