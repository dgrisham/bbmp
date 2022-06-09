#scope_file

#import "Basic";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "String";

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

load_config :: () -> Config {

    path := parse_path(config_filename, false);

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
    }

    config_text, success := read_entire_file(config_filename);
    if !success {
        log("Error reading config at %\n", config_filename, flags=.ERROR);
    }

    config, parse_success := parse_config(*config_text);
    if !parse_success {
        print("aw shucks\n");
        exit(1);
    }

    return config;

    is_newline :: inline (c : u8) -> bool {
        return c == #char "\r" || c == #char "\n";
    }

    parse_config :: (text: *string) -> Config, bool {

        config := Config.{};

        line_number := 1;
        while true {
            error := parse_line(text, *config);
            if error {
                print("Parse error on line %, column %: %\n", line_number, error.position, error.message);
                return config, false;
            }
            line_number += 1;
            if !(<<text) return config, true;
        }

        return config, true;
    }

    Error :: struct {
        position: int;
        message: string;
    }
    New_Error :: (position: int, message: string) -> *Error {
        error := New(Error, allocator=temp);
        error.position = position;
        error.message = message;
        return error;
    }

    parse_line :: (text: *string, config: *Config) -> *Error {

        original_count := text.count;

        while s := <<text { // eat spaces
            if (s[0] != #char " ") && (s[0] != 9) break;
            advance(text, 1);
        }
        if !(<<text) { // blank line
            return null;
        }

        builder: String_Builder;
        builder.allocator = temp;
        init_string_builder(*builder);

        while s := <<text {
            if !is_alnum(s[0]) break;
            append(*builder, s[0]);
            advance(text, 1);
        }
        if !(<<text) {
            return New_Error(original_count - text.count + 1, "reached end of file while parsing config key");
        }

        config_key: enum u8 {
            MPD_HOST;
            MPD_PORT;
            ALBUM_COVER_DIRECTORY;
        } = ---;

        parsed_key := builder_to_string(*builder);
        if parsed_key == {
          case "mpd_host";
            config_key = .MPD_HOST;
          case "mpd_port";
            config_key = .MPD_PORT;
          case "album_cover_directory";
            config_key = .ALBUM_COVER_DIRECTORY;
          case;
            return New_Error(original_count - text.count + 1, tprint("unexpected config key: '%'", parsed_key));
        }

        while s := <<text { // eat spaces
            if (s[0] != #char " ") && (s[0] != 9) break;
            advance(text, 1);
        }
        if !(<<text) {
            return New_Error(original_count - text.count + 1, "reached end of file while parsing config key");
        }

        if (<<text)[0] != #char "=" // =
            return New_Error(original_count - text.count + 1, tprint("Expected '=', got '%'", to_string(*(<<text)[0], 1)));
        advance(text, 1);

        while <<text { // eat spaces
            if ((<<text)[0] != #char " ") && ((<<text)[0] != 9) break;
            advance(text, 1);
        }
        if !(<<text) {
            return New_Error(original_count - text.count + 1, "reached end of file while parsing config key");
        }

        if config_key == {

          case .MPD_HOST;

            reset(*builder);
            while s := <<text {
                if is_space(s[0]) break;
                append(*builder, s[0]);
                advance(text, 1);
            }
            config.mpd_host = builder_to_string(*builder);

          case .MPD_PORT;

            success: bool;
            port: int;
            remainder: string;
            port, success, remainder = to_integer(<<text);
            if !success  return New_Error(original_count - text.count + 1, tprint("Error parsing mpd_port value as integer"));

            if port < 1 || port > 4294967295 { // we accept a u32 because libmpdclient does (u16 is usually the max range)
                return New_Error(original_count - text.count + 1, tprint("Invalid value for mpd_port"));
            }
            <<text = remainder;
            config.mpd_port = cast,no_check(u32)port;

          case .ALBUM_COVER_DIRECTORY;
            reset(*builder);
            while s := <<text {
                if is_space(s[0]) break;
                append(*builder, s[0]);
                advance(text, 1);
            }
            config.album_cover_directory = builder_to_string(*builder);
        }

        while s := <<text { // eat spaces
            if (s[0] != #char " ") && (s[0] != 9) break;
            advance(text, 1);
        }
        if !(<<text) { // blank line
            return null;
        }

        if !is_newline((<<text)[0])  return New_Error(original_count - text.count + 1, tprint("Expected newline, got '%'", to_string(*(<<text)[0], 1)));
        advance(text, 1);

        return null;
    }
}
