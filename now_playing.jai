#scope_file

#import "Basic";
#import "Hash";
#import "File_Utilities";
#import "Math";

#import "common";

MPD   :: #import "libmpdclient";
Simp  :: #import "Simp";
Input :: #import "Input";

log_data :: Log_Data.{"now_playing", false};

loaded_album: struct {
    cover_path  : string;
    song_uri    : string;
    art_texture : *Simp.Texture;
    art_loaded  : bool = false;
}

#scope_export

event_loop :: (albums: [] *Album, total_width: s32, header_bottom: int) {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    if loaded_album.art_texture == null { // initialize loaded art texture, should only happen on the first album view frame
        loaded_album.art_texture = New(Simp.Texture);
    }

    mpd_current_song := MPD.run_current_song(mpd_connection);
    handle_errors("Getting current song");
    if !mpd_current_song return;
    uri := to_string(MPD.song_get_uri(mpd_current_song));
    if loaded_album.song_uri != uri {
        for album, album_index: albums {
            for song, song_index: album.songs {
                if song.uri == uri {
                    if album.cover_path == loaded_album.cover_path { // don't reload the cover if it's the same
                        break;
                    }
                    free(loaded_album.cover_path);
                    free(loaded_album.song_uri);
                    loaded_album.cover_path = copy_string(album.cover_path);
                    loaded_album.song_uri   = copy_string(uri);
                    loaded_album.art_loaded = false;

                    if album.cover_path != "" {
                        display_art_path := tprint("%/%-%x.bmp", config.album_cover_directory, get_hash(tprint("%-%", album.artist_name, album.name)), LARGE_ALBUM_ART_WIDTH);
                        if file_exists(display_art_path) {
                            start := current_time();
                            if !Simp.texture_load_from_file(loaded_album.art_texture, display_art_path) {
                                log("Failed to load display art for % - %", album.artist_name, album.name, flags=.ERROR);
                            } else {
                                log("display album art load time: % ms", (current_time() - start) / 1000.0, flags=.VERBOSE_ONLY);
                                loaded_album.art_loaded = true;
                            }
                        }
                    }
                    break;
                }
            }
        }
    }

   /***********************
    * draw the album cover *
    ***********************/

    cover_display_width  := cast(float)ALBUM_ART_DISPLAY_WIDTH;
    cover_display_height := cover_display_width;

    cover_x := max(cast(float)X_MARGIN_SIZE, cast(float) (total_width - cover_display_width) / 2);
    cover_y := cast(float)(header_bottom - Y_MARGIN_SIZE - cover_display_height) / 2;
    if loaded_album.art_loaded {
        cover_display_height = cover_display_width * cast(float)loaded_album.art_texture.height / loaded_album.art_texture.width;
        remaining_height := cast(float)(header_bottom - Y_MARGIN_SIZE);
        if cover_display_height > remaining_height {
            cover_display_height = remaining_height;
            cover_display_width = cover_display_height * cast(float)loaded_album.art_texture.width / loaded_album.art_texture.height;
        }
        cover_y = cast(float)(header_bottom - cover_display_height) * 5 / 8;

        Simp.set_shader_for_images(loaded_album.art_texture);
        Simp.immediate_begin();

        Simp.immediate_quad(
            xy(cover_x                      , cover_y),
            xy(cover_x + cover_display_width, cover_y),
            xy(cover_x + cover_display_width, cover_y + cover_display_height),
            xy(cover_x                      , cover_y + cover_display_height),
        );

        Simp.immediate_flush();
    }
}
