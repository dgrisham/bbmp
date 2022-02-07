#import "Basic";
#import "Math";
#import "String";
#import "Window_Creation";

Simp  :: #import "Simp";
Input :: #import "Input";
MPD   :: #import "libmpdclient";

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
KEY_H :: 72;
KEY_J :: 74;
KEY_K :: 75;
KEY_L :: 76;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_U :: 85;
KEY_X :: 88;

window: Window_Type;

left_pad :: (str: string, pad_char: u8, total_length: int) -> string {
    result := alloc_string(total_length, __temporary_allocator);
    pad_count := result.count - str.count;
    for 0..(pad_count - 1) result[it] = pad_char;
    memcpy(result.data + pad_count, str.data, str.count);
    return result;
}

right_pad :: (str: string, pad_char: u8, total_length: int) -> string {
    result := alloc_string(total_length, __temporary_allocator);
    memcpy(result.data, str.data, str.count);
    for str.count..(result.count - 1) result[it] = pad_char;
    return result;
}

to_string :: (date: Date) -> string {
    if !date.year  return "";
    if !date.month return tprint("%", date.year);
    month_str := left_pad(tprint("%", date.month), #char "0", 2);
    if !date.day   return tprint("%-%", date.year, month_str);
    day_str := left_pad(tprint("%", date.day), #char "0", 2);
    return tprint("%-%-%", date.year, month_str, day_str);
}

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

    load_library();
    reset_temporary_storage();

    load_queue();

    // TODO: would be nice to generalize this functionality, e.g. binding keys to functionality
    // then having the hold delay -> repeat functionality logic generated automatically (or
    // abstracted + looped)

    library_init_keys();
    queue_init_keys();

    quit := false;
    frame: u64 = 0;

    while !quit {
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
                        load_queue();
                      case .NUMBER_2;
                        current_screen = .LIBRARY;
                    }
                }
            }
        }
        if current_screen == {
          case .LIBRARY;
            library_event_loop(frame);
          case .QUEUE;
            queue_event_loop(frame);
        }
        // TODO: would be good to frame %= LARGE_NUMBER or something so this doesn't overflow,
        // but the *_pressed_on_frame values would need to be updated as well
        frame += 1;
        reset_temporary_storage();
    }

    print("Exiting\n");
    MPD.connection_free(mpd_connection);
}

handle_mpd_idle_events :: () {
  //   assert(mpd_connection != null);
  //   if idle && MPD.send_noidle(mpd_connection) {
  //       idle = false;
		// flags := MPD.recv_idle(mpd_connection, true);
		// MPD.response_finish(mpd_connection);
		// handle_errors("Getting idle events");
  //   }
}

// desktop
window_width  : s32 : 2560;
window_height : s32 : 1440;
pixel_height := window_height / 96;
column_width :: 700;
ITEMS_IN_PAGE :: 50;

// laptop
// window_width  : s32 : 1920;
// window_height : s32 : 1080;
// pixel_height := window_height / 72;
// column_width := 600;
// ITEMS_IN_PAGE := 40;

// desktop - streaming
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

// TODO: add string arg to this to prefix error output with
// handle_errors :: (msg: string) {
//
// returns true if a reconnect happened, false otherwise
handle_errors :: (message: string) -> bool {
    error := check_connection_errors();
    if error {
        print("%: % error, code=%, message='%', recovered=%\n", message, error.type, error.code, error.message, error.recovered);
        if !error.recovered {
            print("Failed to recover from error, attempting to reconnect to MPD\n");

            MPD.run_clear(mpd_connection);
            mpd_connection = MPD.connection_new(null, 0, 0);
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
            mpd_fd = MPD.connection_get_fd(mpd_connection);
            handle_errors("Getting file descriptor for MPD connection");

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
