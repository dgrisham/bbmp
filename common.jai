#scope_file

#import "Basic";
#import "Hash_Table";
#import "Unicode";
#import "Thread";

#import "queue";
#import "config";

Input :: #import "Input";
MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";

#scope_export

config: Config;

mpd_connection: *MPD.connection;

/*********
* logger *
*********/

Log_Data :: struct {
    module  : string;
}
log_history: struct {
    entries     : [..] string;
    first_entry : int = 0;
    max_entries : u32 = 1000;
}

reserve_log_history :: (count: u32) {
    array_reserve(*log_history.entries, count);
    log_history.max_entries = count;
}

DEBUG :: false;
logger :: (message: string, data: *void, info: Log_Info) {
    log_data := cast(*Log_Data) data;
    entry := sprint("[%] %", log_data.module, message);
    if log_history.entries.count == log_history.max_entries {
        old_first_entry := log_history.entries[log_history.first_entry];
        log_history.entries[log_history.first_entry] = entry;
        free(old_first_entry);
        log_history.first_entry += 1;
        if log_history.first_entry == log_history.entries.count {
            log_history.first_entry = 0;
        }
    } else {
        array_add(*log_history.entries, entry);
    }
    #if DEBUG write_string(entry);
}

/************
* constants *
************/

// THUMBNAIL_DIRECTORY :: "/home/grish/src/jai/jai-mpd/.thumbnails";

THUMBNAIL_WIDTH       :: 200;
LARGE_ALBUM_ART_WIDTH :: 800;

MIN_THUMBNAIL_DISPLAY_WIDTH :: 200;

ALBUM_ART_DISPLAY_WIDTH := 600;
MIN_ALBUM_ART_DISPLAY_WIDTH :: 300;

KEY_HOLD_DELAY :: 20;

X_MARGIN_SIZE  : s32;
Y_MARGIN_SIZE  : s32;
TEXT_PADDING_Y :: 5;

SPACE: u8 = 32;
ELLIPSIS :: u8.[226, 128, 166];

/********
* types *
********/

Search_Query :: struct {
    str: string;
    max_characters: int = 100;
}

initialize_search_query :: (search_query: *Search_Query) {
    // the 4x is for big unicode chars
    search_query.str.data = alloc(4 * search_query.max_characters);
    search_query.str.count = 0;
}

append_utf32_to_search_query :: (search_query: *Search_Query, c: u32) -> bool {
    if get_unicode_length(search_query.str) == search_query.max_characters return false;
    input_utf8: string = ---;
    {
        push_allocator(temp);
        input_utf8 = character_utf32_to_utf8(c);
    }
    memcpy(search_query.str.data + search_query.str.count, input_utf8.data, input_utf8.count);
    search_query.str.count += 1;
    return true;
}

// backspace_search_query
backspace_one_character :: (search_query: *Search_Query) {
    if search_query.str == "" return;

    i := 0;
    bytes_in_last_utf8 := 0;
    is_space := false;
    while i < search_query.str.count {
        bytes_in_last_utf8 = 1 + trailingBytesForUTF8[search_query.str.data[i]];
        i += bytes_in_last_utf8;
    }
    is_space = bytes_in_last_utf8 == 1 && search_query.str[search_query.str.count - 1] == SPACE;
    search_query.str.count -= bytes_in_last_utf8;
}

Library_Data :: struct {
    artists             : Table(string, Artist);
    artist_names_sorted : [..] string;
    stats: struct {
        number_of_artists : int = 0;
        number_of_albums  : int = 0;
        number_of_songs   : int = 0;
    }
}

Artist  :: struct {
    name                       : string;
    albums                     : Table(string, Album);
    album_names_sorted_by_date : [..] string;
}

Album :: struct {
    name              : string;
    artist_name       : string;
    date              : Date;
    songs             : [..] Song;
    directory         : string;
    cover_path        : string;
    thumbnail_texture : *Simp.Texture;
    thumbnail_bitmap  : *Simp.Bitmap;
    mutex             : Mutex;
};

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

Date :: struct {
    year  : int;
    month : int;
    day   : int;
}

operator < :: (a: Date, b: Date) -> bool {
    if a.year  < b.year  return true;
    if a.year  > b.year  return false;
    if a.month < b.month return true;
    if a.month > b.month return false;
    if a.day   < b.day   return true;
    if a.day   > b.day   return false;
    return false;
}

parse_date :: (date_str: string) -> Date {
    date: Date;
    success: bool;
    remainder := date_str;

    date.year, success, remainder = to_integer(remainder);
    if !success return date;

    if remainder.count == 0 || remainder[0] != #char "-" return date;
    advance(*remainder, 1);
    date.month, success, remainder = to_integer(remainder);
    if !success return date;

    if remainder.count == 0 || remainder[0] != #char "-" return date;
    advance(*remainder, 1);
    date.day, success, remainder = to_integer(remainder);
    if !success return date;

    return date;
}

to_string :: (date: Date) -> string {
    if !date.year  return "";
    if !date.month return tprint("%", date.year);
    month_str := left_pad(date.month, #char "0", 2);
    if !date.day   return tprint("%-%", date.year, month_str);
    day_str := left_pad(date.day, #char "0", 2);
    return tprint("%-%-%", date.year, month_str, day_str);
}

to_long_date_string :: (date: Date) -> string {
    if !date.year  return "";
    if !date.month return tprint("%", date.year);
    month_name: string;
    if date.month == {
        case 1;  month_name = tprint("January");
        case 2;  month_name = tprint("February");
        case 3;  month_name = tprint("March");
        case 4;  month_name = tprint("April");
        case 5;  month_name = tprint("May");
        case 6;  month_name = tprint("June");
        case 7;  month_name = tprint("July");
        case 8;  month_name = tprint("August");
        case 9;  month_name = tprint("September");
        case 10; month_name = tprint("October");
        case 11; month_name = tprint("November");
        case 12; month_name = tprint("December");
        case;
            log("Warning: '%' is not a valid month number", date.month, flags=.ERROR);
            return tprint("%", date.year);
    }
    if !date.day return tprint("% %", month_name, date.year);
    return tprint("% % %", date.day, month_name, date.year);
}

Display_Text :: struct {
    text     : string;
    selected : bool;
}

/********************************
* MPD connection/error handling *
********************************/

#scope_file

MPD_Error :: struct {
    code: MPD.server_error;
    message: string;
    recovered: bool;
    type: enum { SERVER; CLIENT; };
}

Server_Error :: struct {
    using _error: MPD_Error;
    type = .SERVER;
}

Client_Error :: struct {
    using _error: MPD_Error;
    type = .CLIENT;
}

#scope_export

// returns true if a reconnect happened, false otherwise
handle_errors :: (message: string) -> bool {

    check_connection_errors :: () -> *MPD_Error {
        error_code := MPD.connection_get_error(mpd_connection);
        if (error_code != .SUCCESS) {
            msg := copy_temp_from_c_string(MPD.connection_get_error_message(mpd_connection));

            if error_code == .SERVER {
                error := New(Server_Error, allocator=temp);
                error.code      = MPD.connection_get_server_error(mpd_connection);
                error.message   = msg;
                error.recovered = MPD.connection_clear_error(mpd_connection);
                return error;
            } else {
                error := New(Client_Error, allocator=temp);
                error.message   = msg;
                error.recovered = MPD.connection_clear_error(mpd_connection);
                return error;
            }
        }

        return null;
    }

    error := check_connection_errors();
    if error {
        print("%: % error, code=%, message='%', recovered=%\n", message, error.type, error.code, error.message, error.recovered);
        if !error.recovered {
            print("Failed to recover from error, attempting to reconnect to MPD\n");

            MPD.run_clear(mpd_connection);
            mpd_connection = MPD.connection_new(to_c_string(config.mpd_host), config.mpd_port, 15000);
            if mpd_connection == null {
                print("MPD reconnect failed, might be out of memory. Exiting\n");
                exit(1);
            }

            // TODO: if we get 'connection refused', wait a second before restarting (goes wayy to fast for my laptop)
            new_connection_error := check_connection_errors();
            while new_connection_error {
                MPD.run_clear(mpd_connection);
                mpd_connection = MPD.connection_new(to_c_string(config.mpd_host), config.mpd_port, 0);
                new_connection_error = check_connection_errors();
                print("Failed to reconnect: % error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
                sleep_milliseconds(3000);
            }

            print("Successfully reconnected to MPD\n");
            return true;
        }
        print("Recovered from error\n");
    }
    return false;
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

current_time :: inline () -> u64 {
    return cast(u64)to_microseconds(current_time_monotonic());
}

status_update_timer: u64 = 0;
update_status :: (current_song: *Song) {
    status_update_timer = current_time();

    if current_song {
        status.artist = copy_string(current_song.artist);
        status.album  = copy_string(current_song.album);
        status.song   = copy_string(current_song.name);
    } else {
        status.artist = "";
        status.album  = "";
        status.song   = "";
    }

    mpd_status := MPD.run_status(mpd_connection);
    handle_errors("Retrieving MPD status");
    MPD.response_finish(mpd_connection);
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

/********************
* bulk add to queue *
********************/

add_artist_to_queue :: (library: Library_Data, artist_name: string) -> s32 {
    first_id_added: s32;
    artist := table_find_pointer(library.artists, artist_name);
    if !artist return -1;
    for album_name, album_index: artist.album_names_sorted_by_date {
        album := table_find_pointer(artist.albums, album_name);

        for song, song_index: album.songs {
            id := MPD.run_add_id(mpd_connection, temp_c_string(song.uri));
            if album_index == 0 && song_index == 0 {
                first_id_added = id;
            }
        }
    }
    handle_errors("Adding artist's songs to queue");
    return first_id_added;
}

add_album_to_queue :: (library: Library_Data, artist_name: string, album_name: string) -> s32 {
    first_id_added: s32;
    artist := table_find_pointer(library.artists, artist_name);
    if !artist return -1;
    album := table_find_pointer(artist.albums, album_name);
    if !album return -1;

    for song, song_index: album.songs {
        id := MPD.run_add_id(mpd_connection, temp_c_string(song.uri));
        if song_index == 0 {
            first_id_added = id;
        }
    }
    handle_errors("Adding album's songs to queue");
    return first_id_added;
}

/*******************
* input processing *
*******************/

KEY_B :: 66;
KEY_C :: 67;
KEY_D :: 68;
KEY_F :: 70;
KEY_G :: 71;
KEY_H :: 72;
KEY_I :: 73;
KEY_J :: 74;
KEY_K :: 75;
KEY_L :: 76;
KEY_N :: 78;
KEY_O :: 79;
KEY_P :: 80;
KEY_Q :: 81;
KEY_R :: 82;
KEY_S :: 83;
KEY_U :: 85;
KEY_X :: 88;

Key :: enum u8 {
    ESCAPE;
    ENTER;
    SPACE;
    BACKSPACE;
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
    N;
    O;
    P;
    Q;
    U;
    X;
    SHIFT_J;
    SHIFT_K;
    SHIFT_N;
    CTRL_U;
    CTRL_D;
}

key_held_passed_threshold :: (key_pressed_on_frame: Table(Key, u64), last_key_pressed: Key, frame: u64, $key: Key, threshold := KEY_HOLD_DELAY) -> bool #expand {
    if last_key_pressed != key return false;

    key_code: Input.Key_Code;

         #if key == .B                   key_code = KEY_B;
    else #if key == .F                   key_code = KEY_F;
    else #if key == .H                   key_code = KEY_H;
    else #if key == .J                   key_code = KEY_J;
    else #if key == .K                   key_code = KEY_K;
    else #if key == .L                   key_code = KEY_L;
    else #if key == .N                   key_code = KEY_N;
    else #if key == .X                   key_code = KEY_X;
    else #if key == .EQUALS_SIGN         key_code = .EQUALS_SIGN;
    else #if key == .DASH                key_code = .DASH;
    else #if key == .ENTER               key_code = .ENTER;
    else #if key == .SPACE               key_code = .SPACEBAR;
    else #if key == .BACKSPACE           key_code = .BACKSPACE;
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
    else #if key == .SHIFT_N {
        if !(Input.input_button_states[Input.Key_Code.SHIFT] & .DOWN) return false;
        key_code = KEY_N;
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
    return frame > <<table_find_pointer(key_pressed_on_frame, key) + threshold;
}

/**********
* strings *
**********/

create_temp_display_string_of_max_length :: (s: string, max_character_count: int) -> string {

    num_unicode_chars := get_unicode_length(s);
    if num_unicode_chars <= max_character_count {
        return copy_temporary_string(s);
    }

    // string is too long, trim and replace last char with an ellipses
    max_number_of_bytes := 0;
    num_bytes_in_last_unicode_char := 0;
    {
        bytes_total := 0;
        num_unicode_chars := 0;
        while num_unicode_chars < max_character_count && bytes_total < s.count {
            num_bytes_in_last_unicode_char = 1 + trailingBytesForUTF8[s.data[bytes_total]];
            bytes_total += num_bytes_in_last_unicode_char;
            num_unicode_chars += 1;
        }
        max_number_of_bytes = bytes_total;
    }

    num_bytes_to_copy := max_number_of_bytes - num_bytes_in_last_unicode_char;
    result := alloc_string(num_bytes_to_copy + ELLIPSIS.count, temp);
    memcpy(result.data, s.data, num_bytes_to_copy);
    memcpy(result.data + num_bytes_to_copy, ELLIPSIS.data, ELLIPSIS.count);
    return result;
}

get_unicode_length :: (s: string) -> int {
    length := 0;
    i := 0;
    while i < s.count {
        i += 1 + trailingBytesForUTF8[s.data[i]];
        length += 1;
    }
    return length;
}

seconds_to_time_string :: (seconds: u32, allocator := temp) -> string {
    return aprint("%:%", seconds / 60, left_pad(seconds % 60, #char "0", 2), allocator=allocator);
}

aprint:: (format_string: string, args: .. Any, allocator: Allocator) -> string {
    builder: String_Builder;
    builder.allocator = allocator;
    defer free_buffers(*builder);

    print_to_builder(*builder, format_string, ..args);

    return builder_to_string(*builder, allocator);
}

slice_unicode :: (s: string, index: s64, count: s64) -> string {
    assert(index >= 0, "index = %", index);
    assert(count >= 0, "count = %", count);
    unicode_length := get_unicode_length(s);
    if index >= unicode_length  return "";

    unicode_index := 0;
    length := 0;
    while length < index {
        utf8_bytes := 1 + trailingBytesForUTF8[s.data[length]];
        length += 1;
        unicode_index += utf8_bytes;
    }

    if index + count > unicode_length {
        count = unicode_length - unicode_index;
    }

    unicode_count := unicode_index;
    length = 0;
    while length < count {
        utf8_bytes := 1 + trailingBytesForUTF8[s.data[unicode_count]];
        length += 1;
        unicode_count += utf8_bytes;
    }

    c: string = ---;
    c.data    = s.data + index;
    c.count   = unicode_count;
    return c;
}

copy_from_c_string :: inline (s: *u8) -> string {
    return copy_string(to_string(s));
}

copy_temp_from_c_string :: inline (s: *u8) -> string {
    return copy_temporary_string(to_string(s));
}

left_pad :: (t: $T, pad_char: u8, total_length: int, allocator := temp) -> string {
    #if T == string str := t;
    else            str := tprint("%", t);

    if total_length <= 0 return str;
    result := alloc_string(total_length, allocator);
    pad_count := result.count - str.count;
    for 0..(pad_count - 1) result[it] = pad_char;
    memcpy(result.data + pad_count, str.data, str.count);
    return result;
}

right_pad :: (t: $T, pad_char: u8, total_length: int, allocator := temp) -> string {
    #if T == string str := t;
    else            str := tprint("%", t);

    result := alloc_string(total_length, allocator);
    memcpy(result.data, str.data, str.count);
    for str.count..(result.count - 1) result[it] = pad_char;
    return result;
}
