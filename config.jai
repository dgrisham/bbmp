#scope_file

#scope_export

// mpd_host = localhost
// mpd_port = 6600
// album_cover_directory = "/home/grish/src/jai/jai-mpd/.thumbnails"

Config :: struct {
    mpd_host: string = "localhost";
    mpd_port: u32 = 6600;
    album_cover_directory: string = "/home/grish/src/jai/jai-mpd/.thumbnails"; // TODO: set default based on OS
}

load_config :: () -> Config {
    return Config.{};
}
