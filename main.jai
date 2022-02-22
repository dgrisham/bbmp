#import "Basic";
#import "Math";
#import "String";
#import "Window_Creation";
#import "POSIX";
#import "Time";

Process :: #import "Process";
Simp    :: #import "Simp";
Input   :: #import "Input";
MPD     :: #import "libmpdclient";

Song :: struct {
    artist   : string;
    album    : string;
    name     : string;
    track    : string;
    uri      : string;
    duration : u32;
}
free :: (using song: Song) {
    free(artist);
    free(album);
    free(name);
    free(track);
    free(uri);
}

seconds_to_time_string :: (seconds: u32, allocator := __temporary_allocator) -> string {
    return aprint("%:%", seconds / 60, left_pad(seconds % 60, #char "0", 2), allocator=allocator);
}
aprint:: (format_string: string, args: .. Any, allocator: Allocator) -> string {
    builder: String_Builder;
    builder.allocator = allocator;
    defer free_buffers(*builder);

    print_to_builder(*builder, format_string, ..args);

    return builder_to_string(*builder, allocator);
}

Display_Text :: struct {
    text     : string;
    selected : bool;
}

#load "queue.jai";
#load "library.jai";
#load "library_album_art.jai";

KEY_B :: 66;
KEY_C :: 67;
KEY_D :: 68;
KEY_F :: 70;
KEY_G :: 71;
KEY_H :: 72;
KEY_J :: 74;
KEY_K :: 75;
KEY_L :: 76;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_R :: 82;
KEY_U :: 85;
KEY_X :: 88;

Key :: enum u8 {
    ENTER;
    SPACE;
    LEFT_ANGLE_BRACKET;
    RIGHT_ANGLE_BRACKET;
    EQUALS_SIGN;
    DASH;
    B;
    C;
    D;
    F;
    G;
    H;
    J;
    K;
    L;
    O;
    P;
    Q;
    U;
    X;
    SHIFT_J;
    SHIFT_K;
    CTRL_U;
    CTRL_D;
}

window: Window_Type;

copy_from_c_string :: inline (s: *u8) -> string {
    return copy_string(to_string(s));
}

copy_temp_from_c_string :: inline (s: *u8) -> string {
    return copy_temporary_string(to_string(s));
}

Screen :: enum {
    QUEUE;
    LIBRARY;
    LIBRARY_ALBUM_ART;
}

current_screen := Screen.LIBRARY;

LONG         : s32 : 0x200000;
TCP_NODELAY  : s32 : LONG + xx 121;

mpd_connection: *MPD.connection;
mpd_fd: s32;
idle := false;
// mpd_poll_process_pid: pid_t;

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

KEY_HOLD_DELAY :: 20;

window_width  : s32 = 1920;
window_height : s32 = 1080;

X_MARGIN_SIZE  : s32;
Y_MARGIN_SIZE  : s32;
TEXT_PADDING_Y :: 5;

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

    mpd_connection = MPD.connection_new(null, 0, 15000);
    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors("Initializing MPD connection");

    // mpd_fd = MPD.connection_get_fd(mpd_connection);
    // handle_errors("Getting file descriptor for MPD connection");
    // flag: int = 1;
    // setsockopt(mpd_fd, IPPROTO_TCP, TCP_NODELAY, *flag, size_of(type_of(flag)));

    // pid := fork_poll_process(mpd_fd);
    // if pid > 0 {
    //     mpd_poll_process_pid = pid;
    // }

    load_library();
    load_queue();
    load_library_album_art();

    library_init_repeatable_keys();
    queue_init_repeatable_keys();

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

        // if !idle MPD.send_idle(mpd_connection);
        // handle_errors("Putting MPD into idle mode");
        // idle = true;

        Input.update_window_events();

        for Input.get_window_resizes() {
            Simp.update_window(it.window);
            if it.window == window {
                if (it.width != window_width) || (it.height != window_height) {
                    window_width  = it.width;
                    window_height = it.height;
                    X_MARGIN_SIZE = window_width / 30;
                    Y_MARGIN_SIZE = window_height / 30;
                    init_fonts();
                    break;
                }
            }
        }

        seek :: ($seconds: float32) #expand {
            handle_mpd_idle_events();
            MPD.run_seek_current(mpd_connection, seconds, true);
            handle_errors("Seeking");
            update_status_time();
        }
        SEEK_SECONDS :: 0.5;
        seek_forward  :: () #expand { seek( SEEK_SECONDS); }
        seek_backward :: () #expand { seek(-SEEK_SECONDS); }

        play_previous_song :: () #expand {
            last_global_key_pressed = .LEFT_ANGLE_BRACKET;
            handle_mpd_idle_events();
            MPD.run_previous(mpd_connection);
            handle_errors("Playing previous song");
            update_status(false);
        }
        play_next_song :: () #expand {
            handle_mpd_idle_events();
            MPD.run_next(mpd_connection);
            handle_errors("Playing next song");
            update_status(false);
        }

        change_volume :: ($amount: s32) #expand {
            handle_mpd_idle_events();
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
                        quit = true;
                        break it;

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
                        handle_mpd_idle_events();
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
                        handle_mpd_idle_events();
                        MPD.run_clear(mpd_connection);
                        handle_errors("Clearing queue");
                        load_queue_changes();
                        update_status();
                        break it;
                    }
                }
            }
        }

        if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .B)                   seek_backward();
        if key_held_passed_threshold(global_key_pressed_on_frame, last_global_key_pressed, frame, .F)                   seek_forward();
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

    // print("Killing child process\n");
    // if kill(mpd_poll_process_pid, SIGKILL) == -1
    //     print("Failed to kill the child %: %\n", mpd_poll_process_pid, errno());

    MPD.connection_free(mpd_connection);
}

key_held_passed_threshold :: (key_pressed_on_frame: Table(Key, u64), last_key_pressed: Key, frame: u64, $key: Key) -> bool #expand {
    if last_key_pressed != key return false;

    key_code: Input.Key_Code;

         #if key == .B                   key_code = KEY_B;
    else #if key == .F                   key_code = KEY_F;
    else #if key == .H                   key_code = KEY_H;
    else #if key == .J                   key_code = KEY_J;
    else #if key == .K                   key_code = KEY_K;
    else #if key == .L                   key_code = KEY_L;
    else #if key == .X                   key_code = KEY_X;
    else #if key == .EQUALS_SIGN         key_code = .EQUALS_SIGN;
    else #if key == .DASH                key_code = .DASH;
    else #if key == .ENTER               key_code = .ENTER;
    else #if key == .SPACE               key_code = .SPACEBAR;
    else #if key == .LEFT_ANGLE_BRACKET  key_code = .LEFT_ANGLE_BRACKET;
    else #if key == .RIGHT_ANGLE_BRACKET key_code = .RIGHT_ANGLE_BRACKET;
    else #if key == .SHIFT_J {
        if !(Input.input_button_states[Input.Key_Code.SHIFT] & .DOWN) return false;
        key_code = KEY_J;
    }
    else #if key == .SHIFT_K {
        if !(Input.input_button_states[Input.Key_Code.SHIFT] & .DOWN) return false;
        key_code = KEY_K;
    }
    else #if key == .CTRL_D {
        if !(Input.input_button_states[Input.Key_Code.CTRL] & .DOWN) return false;
        key_code = KEY_D;
    }
    else #if key == .CTRL_U {
        if !(Input.input_button_states[Input.Key_Code.CTRL] & .DOWN) return false;
        key_code = KEY_U;
    }
    else #assert(false);

    if !(Input.input_button_states[key_code] & .DOWN) return false;
    return frame > <<table_find_pointer(key_pressed_on_frame, key) + KEY_HOLD_DELAY;
}

draw_header :: () -> int {

    top := cast(int)window_height - 2 * Y_MARGIN_SIZE;

    header_bottom := top;
    {
        x := X_MARGIN_SIZE;
        y := top - TEXT_PADDING_Y - font.character_height;
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

    {
        x := cast(int)window_width / 2;
        y := top;

        // song name
        max_characters_in_column := (display_width() / 2) / font.w_width;
        text_width := Simp.prepare_text(font, slice(status.song, 0, max_characters_in_column));
        Simp.draw_prepared_text(font, x - text_width / 2, y, rgba(1,1,1,1));

        y -= TEXT_PADDING_Y + font.character_height;

        // artist - album
        text_width = Simp.prepare_text(font, slice(tprint("% - %", status.artist, status.album), 0, max_characters_in_column));
        Simp.draw_prepared_text(font, x - text_width / 2, y, rgba(1,1,1,1));

        header_bottom = min(header_bottom, y - font.character_height);
    }

    {
        x := display_width() + X_MARGIN_SIZE - font.w_width * 10;
        y := top - TEXT_PADDING_Y - font.character_height;
        Simp.draw_text(
            font,
              x,
              y,
              tprint("Vol: %1%%", left_pad(status.volume, #char " ", 3)),
              rgba(1,1,1,1),
        );
        header_bottom = min(header_bottom, y - font.character_height);
    }

    return header_bottom;
}

// fork_poll_process :: (mpd_fd: s32) -> pid_t {
//     pid := fork();

//     if pid < 0 {
//         log_error("Error forking MPD connection fd poll process: %\n", errno());
//         return -1;
//     }
//     if pid == 0 {
//         mpd_async := MPD.async_new(mpd_fd);
//         if !mpd_async { print("Error creating async MPD connection\n"); exit(1); }

//         while true {
//             poll_fds: [1] pollfd;
//             poll_fds[0].fd = mpd_fd;
//             poll_fds[0].events = POLLIN;

//             poll(poll_fds.data, cast(u32) poll_fds.count, -1);
//             if poll_fds[0].revents & POLLIN {
//                 print("FD ready for reading\n");
//                 handle_mpd_idle_events();
//             }
//             sleep_milliseconds(5000);
//         }
//     }

//     return pid;
// }

handle_mpd_idle_events :: () {
    assert(mpd_connection != null);
    // print("Checking MPD idle events\n");
    if idle && MPD.send_noidle(mpd_connection) {
        idle = false;
        flags := MPD.recv_idle(mpd_connection, true);
        print("flags: %\n", flags);
        MPD.response_finish(mpd_connection);
        handle_errors("Getting idle events");

        // if flags & .QUEUE load_queue_changes();
    }
}

// pixel_height := window_height / 48;

// TODO: load/use font for asian/etc. characters (maybe one of the expanded inconsolata sets?)
font, font_bold : *Simp.Dynamic_Font;
init_fonts :: () {
    pixel_height := window_height / (ifx window_height > 1080 then 96 else 72);
    // streaming
    // pixel_height := window_height / 56;

    if (font != null) free(font);
    font = Simp.get_font_at_size(".", "Inconsolata-Regular.ttf", pixel_height);
    assert(font != null);

    // if (font_bold != null) free(font_bold);
    // font_bold = Simp.get_font_at_size(".", "Inconsolata-SemiBold.ttf", pixel_height);
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

            // if kill(mpd_poll_process_pid, SIGKILL) == -1
            //     print("Failed to kill the child %: %\n", mpd_poll_process_pid, errno());
            // mpd_fd = MPD.connection_get_fd(mpd_connection);
            // handle_errors("Getting file descriptor for MPD connection");
            // flag: int = 1;
            // setsockopt(mpd_fd, IPPROTO_TCP, TCP_NODELAY, *flag, size_of(type_of(flag)));

            // pid := fork_poll_process(mpd_fd);
            // if pid > 0 {
            //     mpd_poll_process_pid = pid;
            // }

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

left_pad :: (t: $T, pad_char: u8, total_length: int, allocator := __temporary_allocator) -> string {
    #if T == string str := t;
    else            str := tprint("%", t);

    if total_length <= 0 return str;
    result := alloc_string(total_length, allocator);
    pad_count := result.count - str.count;
    for 0..(pad_count - 1) result[it] = pad_char;
    memcpy(result.data + pad_count, str.data, str.count);
    return result;
}

right_pad :: (t: $T, pad_char: u8, total_length: int, allocator := temporary_allocator) -> string {
    #if T == string str := t;
    else            str := tprint("%", t);

    result := alloc_string(total_length, allocator);
    memcpy(result.data, str.data, str.count);
    for str.count..(result.count - 1) result[it] = pad_char;
    return result;
}
