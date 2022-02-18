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

draw_library_album_art_frame :: (items_in_page: int, header_bottom: int) {

    create_album_art_thumbnail :: (uri: string, thumbnail_path: string) -> bool {
        THUMBNAIL_WIDTH :: 300;

        // load the album art from MPD
        album_art_data: [..] u8;
        defer array_free(album_art_data);
        if !load_album_art(uri, *album_art_data) {
            log(tprint("Failed to load album art for song URI '%'", uri), flags=.ERROR);
            return false;
        }

        // load the raw data into a bitmap
        bitmap: Simp.Bitmap;
        defer Simp.deinit(*bitmap);
        if !Simp.bitmap_load_from_memory(*bitmap, album_art_data) {
            log(tprint("Failed to load album art into bitmap for song URI '%'", uri), flags=.ERROR);
            return false;
        }

        // resize to thumbnail size
        resized_bitmap: Simp.Bitmap;
        Simp.bitmap_resize(*bitmap, THUMBNAIL_WIDTH, cast(s32)(bitmap.height * cast(float64)THUMBNAIL_WIDTH / bitmap.width), *resized_bitmap);
        defer Simp.deinit(*resized_bitmap);

        // save the thumbnail
        if !Simp.bitmap_save(*resized_bitmap, thumbnail_path) {
            log(tprint("Failed to save album art thumbnail to '%'", thumbnail_path), flags=.ERROR);
            return false;
        }

        return true;
    }

    artist_name := "Metallica";
    artist := table_find_pointer(library.artists, artist_name);
    assert(artist != null);
    album_name := "Master of Puppets";
    album := table_find_pointer(artist.albums, album_name);
    assert(album != null);
    assert(album.songs.count > 0);

    uri := album.songs[0].uri;
    thumbnail_path := "/home/grish/src/jai/jai-mpd/test.bmp";

    if !create_album_art_thumbnail(uri, thumbnail_path) {
        log(tprint("Failed to create thumbnail for % - %", artist_name, album_name), flags=.ERROR);
    }

    texture := New(Simp.Texture);
    assert(Simp.texture_load_from_file(texture, thumbnail_path));
}

BUFFER_MAX :: 8192;
load_album_art :: (uri: string, data: *[..] u8) -> success: bool {
    assert(data.count == 0);

    buffer: [BUFFER_MAX] u8;
    while true {
        bytes_read := MPD.run_albumart(mpd_connection, uri.data, cast(u32)data.count, buffer.data, BUFFER_MAX);
        if bytes_read < 0 {
            handle_errors(tprint("Retrieving album art for song uri: %", uri));
            return false;
        }
        array_add(data, ..buffer);
        if bytes_read < BUFFER_MAX return true;
    }

    return true;
}
