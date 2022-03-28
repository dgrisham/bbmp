/************
* constants *
************/

THUMBNAIL_DIRECTORY :: "/home/grish/src/jai/jai-mpd/.thumbnails";

THUMBNAIL_WIDTH       :: 200;
LARGE_ALBUM_ART_WIDTH :: 600;

ALBUM_ART_DISPLAY_WIDTH := 600;

KEY_HOLD_DELAY :: 20;

X_MARGIN_SIZE  : s32;
Y_MARGIN_SIZE  : s32;
TEXT_PADDING_Y :: 5;

/********
* types *
********/

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
    if !date.day   return tprint("% %", month_name, date.year);
    return tprint("% % %", date.day, month_name, date.year);
}

Display_Text :: struct {
    text     : string;
    selected : bool;
}

/********************
* bulk add to queue *
********************/

add_artist_to_queue :: (artist_name: string) -> s32 {
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

add_album_to_queue :: (artist_name: string, album_name: string) -> s32 {
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

key_held_passed_threshold :: (key_pressed_on_frame: Table(Key, u64), last_key_pressed: Key, frame: u64, $key: Key, threshold := KEY_HOLD_DELAY) -> bool #expand {
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
    result := alloc_string(num_bytes_to_copy + ELLIPSIS.count, __temporary_allocator);
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
