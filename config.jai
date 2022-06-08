#scope_file

#import "Basic";
#import "File_Utilities";
#import "Hash_Table";

#import "Print_Color";

// TODO
//  - read XDG_CONFIG_HOME on linux
//  - figure out windows default
//  - osx?
//  - support command line flag w/ expansion

// config_filename := "./.grishcompooprc";
config_filename := "/home/grish/src/jai/jai-mpd/.grishcompooprc";

#scope_export

// mpd_host = localhost
// mpd_port = 6600
// album_cover_directory = "/home/grish/src/jai/jai-mpd/.thumbnails"

Config :: struct {
    mpd_host: string = "localhost";
    mpd_port: u32 = 6600;
    album_cover_directory: string = "/home/grish/src/jai/jai-mpd/.thumbnails"; // TODO: set default based on OS
}

Error :: *string;
load_config :: () -> Config {

    config := Config.{};

    path := reduce_path(parse_path(config_filename, false));

    file_exists, how_much_exists := how_much_of_path_exists_on_the_local_filesystem(path);
    if !file_exists {
        partial := path;
        partial.words.count = how_much_exists;
        partial_string := path_to_string(partial);
        print("This much exists: %\n", partial_string);

        remainder: Path;
        remainder.trailing_slash = path.trailing_slash;

        remainder_words := path.words;
        remainder_words.data += how_much_exists;
        remainder_words.count -= how_much_exists;

        remainder.words = remainder_words;
        remainder_string := path_to_string(remainder);

        print_color("%/",  partial_string,   color=FOREGROUND_GREEN);
        print_color("%\n", remainder_string, color=FOREGROUND_RED);
    } else {
        print("EXISTS\n");
    }

    // read_entire_file

    // if key == {
    //   case "mpd_host";
    //     config.mpd_host = value;
    //   case "mpd_port";
    //     config.mpd_port = value;
    //   case "album_cover_directory";
    //     config.albumcover = value;
    // }

    return Config.{};
}
