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

SEEK_SECONDS         :: 0.5;
VOLUME_CHANGE_AMOUNT :: 2;

Song :: struct {
    artist : string;
    album  : string;
    name   : string;
    track  : string;
    uri    : string;
}
free :: (using song: Song) {
    free(artist);
    free(album);
    free(name);
    free(track);
    free(uri);
}

#load "library.jai";
#load "queue.jai";

KEY_B :: 66;
KEY_C :: 67;
KEY_D :: 68;
KEY_F :: 70;
KEY_G :: 71;
KEY_H :: 72;
KEY_J :: 74;
KEY_K :: 75;
// TODO: shift keys are kind of forced (we're just taking advantage of unused
// key values, where a-z starts at 65 and A-Z at 97, but here lowercase + capitals
// are flipped because the shift key is treated as a separate thing. not sure if
// this is something that'll cause problems later. shift key logic generally worth
// reconsidering, kind of ad-hoc)
KEY_SHIFT_J :: KEY_J + 32;
KEY_SHIFT_K :: KEY_K + 32;
KEY_L :: 76;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_U :: 85;
KEY_X :: 88;

window: Window_Type;

mpd_connection: *MPD.connection;
mpd_fd: s32;
idle := false;

copy_from_c_string :: inline (s: *u8) -> string {
    return copy_string(to_string(s));
}

Screen :: enum {
    LIBRARY;
    QUEUE;
}

current_screen := Screen.LIBRARY;

LONG         : s32 : 0x200000;
TCP_NODELAY  : s32 : LONG + xx 121;

mpd_poll_process_pid: pid_t;

frame: u64 = 0;
frame_rate: float64;
target_fps :: 30;
max_ms_per_frame :: 1000.0 / target_fps;

Status :: struct {
    artist:       string;
    album:        string;
    song:         string;
    elapsed_time: u32;
    total_time:   u32;
    volume:       s32;
}

main :: () {

    init_fonts();

    window = create_window(window_width, window_height, "ncmpjai");
    Simp.set_render_target(window);

    mpd_connection = MPD.connection_new(null, 0, 15000);
    if mpd_connection == null {
        print("Out of memory\n");
        exit(1);
    }
    handle_errors("Initializing MPD connection");

    mpd_fd = MPD.connection_get_fd(mpd_connection);
    handle_errors("Getting file descriptor for MPD connection");
    flag: int = 1;
    setsockopt(mpd_fd, IPPROTO_TCP, TCP_NODELAY, *flag, size_of(type_of(flag)));

    // pid := fork_poll_process(mpd_fd);
    // if pid > 0 {
    //     mpd_poll_process_pid = pid;
    // }

    load_library();
    load_queue();

    // TODO: would be nice to generalize this functionality, e.g. binding keys to functionality
    // then having the hold delay -> repeat functionality logic generated automatically (or
    // abstracted + looped)

    library_init_keys();
    queue_init_keys();

    quit := false;
    frame: u64 = 0;
    status_update_timer: u64 = 0;

    status: Status;
    while !quit {
        if get_current_file_time() > status_update_timer + 10000000 {
            status_update_timer = get_current_file_time();

            mpd_status := MPD.run_status(mpd_connection);
            handle_errors("Retrieving MPD status");
    		MPD.response_finish(mpd_connection);

            load_queue_changes(); // TODO: load queue diff
            queue_song_position := MPD.status_get_song_pos(mpd_status);
            if queue_song_position >= 0 {
                song := queue.songs[queue_song_position];
                status.artist = song.artist;
                status.album  = song.album;
                status.song   = song.name;
            } else {
                status.artist = "";
                status.album  = "";
                status.song   = "";
            }
            status.elapsed_time = MPD.status_get_elapsed_time(mpd_status);
            status.total_time   = MPD.status_get_total_time(mpd_status);
            status.volume       = MPD.status_get_volume(mpd_status); // TODO: update volume when user changes it
            MPD.status_free(mpd_status);
        }
        frame_start := get_current_file_time();

        // if !idle MPD.send_idle(mpd_connection);
        // handle_errors("Putting MPD into idle mode");
        // idle = true;

        Input.update_window_events();

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
                    }
                }
            }
        }

        Simp.clear_render_target(0,0,0,1);
        draw_header(status);
        if current_screen == {
          case .LIBRARY;
            library_event_loop(frame);
          case .QUEUE;
            queue_event_loop(frame);
        }
        Simp.swap_buffers(window);
        reset_temporary_storage();

        // TODO: would be good to frame %= LARGE_NUMBER or something so this doesn't overflow,
        // but the *_pressed_on_frame values would need to be updated as well
        frame += 1;

        calculate_frame_rate :: (start: u64, end: u64) -> float64 {
            return 10000000.0 / (end - start);
        }

        frame_rate = calculate_frame_rate(frame_start, get_current_file_time());
        frame_time_ms := 1000 / frame_rate;
        if frame_time_ms < max_ms_per_frame {
            sleep_milliseconds(cast(s32) (max_ms_per_frame - frame_time_ms));
        }
        frame_rate = calculate_frame_rate(frame_start, get_current_file_time());
        if !(frame % target_fps) print("frame rate: %\n", frame_rate);
    }

    print("Killing child process\n");
    if kill(mpd_poll_process_pid, SIGKILL) == -1
        print("Failed to kill the child %: %\n", mpd_poll_process_pid, errno());

    MPD.connection_free(mpd_connection);
}

// Status :: struct {
//     artist:       string;
//     album:        string;
//     song:         string;
//     elapsed_time: u32;
//     total_time:   u32;
// }

left  : int : 50;
right : int : cast(int)window_width - 25;
display_width :: right - left;
DISPLAY_TOP    :: cast(int)window_height - 50;
DISPLAY_BOTTOM :: 50;

ITEMS_IN_PAGE : int;
HEADER_BOTTOM    : int;

draw_header :: (status: Status) {
    top := cast(int)window_height - 100;
    text_padding_y :: 5;

    seconds_to_time_display :: (seconds: u32) -> string {
        return tprint("%:%", seconds / 60, left_pad(seconds % 60, #char "0", 2));
    }

    min_y := top;

    {
        x := left;
        y := top - text_padding_y - font.character_height;
        Simp.draw_text(
            font,
              x,
              y,
              tprint("%/%", seconds_to_time_display(status.elapsed_time), seconds_to_time_display(status.total_time)),
              rgba(1,1,1,1),
        );

        min_y = min(min_y, y - font.character_height);
    }

    {
        x := cast(int)window_width / 2;
        y := top;

        // song name
        max_characters_in_column := (display_width / 2) / font.em_width;
        text_width := Simp.prepare_text(font, slice(status.song, 0, max_characters_in_column));
        Simp.draw_prepared_text(font, x - text_width / 2, y, rgba(1,1,1,1));

        y -= text_padding_y + font.character_height;

        // artist - album
        text_width = Simp.prepare_text(font, slice(tprint("% - %", status.artist, status.album), 0, max_characters_in_column));
        Simp.draw_prepared_text(font, x - text_width / 2, y, rgba(1,1,1,1));

        min_y = min(min_y, y - font.character_height);
    }

    {
        x := right - font.em_width * 10 - (window_width - right);
        y := top - text_padding_y - font.character_height;
        Simp.draw_text(
            font,
              x,
              y,
              tprint("Vol: %1%%", left_pad(status.volume, #char " ", 3)),
              rgba(1,1,1,1),
        );
        min_y = min(min_y, y - font.character_height);
    }

    // TODO: these are still being experimented with
    HEADER_BOTTOM = min_y;
    ITEMS_IN_PAGE = (HEADER_BOTTOM - DISPLAY_BOTTOM) / (font.character_height + text_padding_y);
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

		// if flags & .QUEUE load_queue();
    }
}

// // desktop
window_width  : s32 : 2560;
window_height : s32 : 1440;
pixel_height := window_height / 96;
// column_width :: 700;
// ITEMS_IN_PAGE :: 50;

// laptop
// window_width  : s32 : 1920;
// window_height : s32 : 1080;
// pixel_height := window_height / 72;
// ITEMS_IN_PAGE := 40;

// // desktop - streaming
// window_width  : s32 : 1900;
// window_height : s32 : 1440;
// pixel_height := window_height / 48;
// column_width :: 600;
// ITEMS_IN_PAGE :: 30;

// TODO: load/use font for asian/etc. characters (maybe one of the expanded inconsolata sets?)
font, font_bold : *Simp.Dynamic_Font;
init_fonts :: () {

    font = Simp.get_font_at_size(".", "Inconsolata-Regular.ttf", pixel_height);
    assert(font != null);

    font_bold = Simp.get_font_at_size(".", "Inconsolata-SemiBold.ttf", pixel_height);
    assert(font_bold != null);
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

            if kill(mpd_poll_process_pid, SIGKILL) == -1
                print("Failed to kill the child %: %\n", mpd_poll_process_pid, errno());
            mpd_fd = MPD.connection_get_fd(mpd_connection);
            handle_errors("Getting file descriptor for MPD connection");
            flag: int = 1;
            setsockopt(mpd_fd, IPPROTO_TCP, TCP_NODELAY, *flag, size_of(type_of(flag)));

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
		msg := copy_from_c_string(MPD.connection_get_error_message(mpd_connection));

		if error_code == .SERVER {
    		error := New(Server_Error);
			error.code      = MPD.connection_get_server_error(mpd_connection);
			error.recovered = MPD.connection_clear_error(mpd_connection);
			return error;
		} else {
    		error := New(Client_Error);
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
