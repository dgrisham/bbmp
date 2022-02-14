#import "Hash_Table";
#import "Unicode";

last_library_album_art_key_pressed: Key;
library_album_art_key_pressed_on_frame: Table(Key, u64);

library_album_art_init_repeatable_keys :: () {
    table_set(*library_album_art_key_pressed_on_frame, .J,      0);
    table_set(*library_album_art_key_pressed_on_frame, .K,      0);
    table_set(*library_album_art_key_pressed_on_frame, .L,      0);
    table_set(*library_album_art_key_pressed_on_frame, .H,      0);
    table_set(*library_album_art_key_pressed_on_frame, .CTRL_D, 0);
    table_set(*library_album_art_key_pressed_on_frame, .CTRL_U, 0);
    table_set(*library_album_art_key_pressed_on_frame, .SPACE,  0);
}

library_album_art_event_loop :: (frame: u64, header_bottom: int) {

    items_in_page := (header_bottom - 2 * Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);

    draw_library_album_art_frame(items_in_page, header_bottom);
}

BUFFER_MAX :: 8192;
draw_library_album_art_frame :: (items_in_page: int, header_bottom: int) {

    artist := table_find_pointer(library.artists, "Metallica");
    assert(artist != null);
    album := table_find_pointer(artist.albums, "Master of Puppets");
    assert(album != null);
    assert(album.songs.count > 0);

    uri := album.songs[0].uri;
    album_cover_data: [..] u8;
    print("uri: %\n", uri);
    album_initial := get_current_file_time();

    // art_texture := New(Simp.Texture);
    // assert(Simp.texture_load_from_file(art_texture, "/home/grish/media/music/library/metallica/1986_02-master_of_puppets/cover.jpg", srgb=true));
    // print("DIRECT ART FILE LOAD TIME: % ms\n", (get_current_file_time() - album_initial) / 10000.0);

    assert(MPD.run_binarylimit(mpd_connection, BUFFER_MAX));
    assert(read_album_cover(uri, *album_cover_data));
    print("ART LOAD TIME: % ms\n", (get_current_file_time() - album_initial) / 10000.0);

    art_texture := New(Simp.Texture);
    simp_initial := get_current_file_time();
    print("album_cover_data.count: %\n", album_cover_data.count);
    print("album_cover_data.data: %\n", to_string(album_cover_data.data));

    assert(Simp.texture_load_from_memory(art_texture, album_cover_data, srgb=true));
    print("SIMP TEXTURE TIME: % ms\n", (get_current_file_time() - simp_initial) / 10000.0);
    print("TOTAL TIME: % ms\n", (get_current_file_time() - album_initial) / 10000.0);
}

read_album_cover :: (uri: string, data: *[..] u8) -> success: bool {
    assert(data.count == 0);

    buffer: [BUFFER_MAX] u8;
    while true {
        bytes_read := MPD.run_albumart(mpd_connection, uri.data, cast(u32)data.count, buffer.data, BUFFER_MAX);

        if bytes_read < 0 {
            handle_errors(tprint("Retrieving album cover for song uri: %", uri));
            return false;
        }

        array_add(data, ..buffer);
        if bytes_read < BUFFER_MAX return true;
    }

    return true;
}
