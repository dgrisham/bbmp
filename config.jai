#scope_file

#import "Basic";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "POSIX";
#import "String";

#import "Print_Color";

#import "common";

log_data :: Log_Data.{"config_loader", false};

#scope_export

// example config file:
//
// ```
// mpd_host = localhost
// mpd_port = 6600
// max_log_size = 10000
// log_level = verbose
// mpd_library_directory = ~/media/music/library
// album_cover_directory = /home/grish/src/jai/jai-mpd/.thumbnails
// ```

Config :: struct {
    mpd_host              : string    = "localhost";
    mpd_port              : u32       = 6600;
    max_log_size          : u32       = 1000;
    log_level             : Log_Level = .NORMAL;
    mpd_library_directory : string;
    album_cover_directory : string;
}

load_config :: () -> Config, bool {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    config_file_loaded := false;

    // default config file to $XDG_CONFIG_HOME/grishcompoop/grishcompooprc if XDG_CONFIG_HOME is set, otherwise ~/.grishcompooprc (and expand the ~ later)
    config_filename := "~/.grishcompooprc";
    config_directory_env_var := getenv("XDG_CONFIG_HOME");
    if config_directory_env_var {
        config_filename = sprint("%/grishcompoop/grishcompooprc", to_string(config_directory_env_var));
    }

    success: bool;
    config_filename, success = expand_path(config_filename);
    if !success {
        log("Failed to expand config path '%'", config_filename, flags=.ERROR);
    }

    path := parse_path(config_filename, false);

    config := Config.{};

    file_exists, how_much_exists := how_much_of_path_exists_on_the_local_filesystem(path);
    if !file_exists {
        partial := path;
        partial.words.count = how_much_exists;
        partial_string := path_to_string(partial);

        remainder: Path;
        remainder.trailing_slash = path.trailing_slash;

        remainder_words := path.words;
        remainder_words.data  += how_much_exists;
        remainder_words.count -= how_much_exists;

        remainder.words = remainder_words;
        remainder_string := path_to_string(remainder);

        // TODO: output this in the actual program (not just the console)
        print_color("%/",  partial_string,   color=FOREGROUND_GREEN);
        print_color("%\n", remainder_string, color=FOREGROUND_RED);

        log("Config file does not exist at '%'", config_filename, flags=.WARNING);

        free(partial_string);
        free(remainder_string);
     } else {
        config_text, success := read_entire_file(config_filename);
        if !success {
            log("Error reading config at %", config_filename, flags=.ERROR);
        } else {
            // parse the config
            line_number := 1;
            while true {
                error := parse_line(*config_text, *config);
                if error {
                    log("Parse error on line %, column %: %", line_number, error.position, error.message, flags=.ERROR);
                    // TODO: we have a memory leak here if string field was allocated in parse_line!
                    // But we can't just always free the strings, because the default constant strings can't be freed
                    // Best solution might be to do temp allocations, then copy once we know we've succeeded
                    config = Config.{};
                    break;
                }
                line_number += 1;
                if !config_text {
                    config_file_loaded = true;
                    break;
                }
            }
        }
    }

    album_cover_directory := config.album_cover_directory;
    if album_cover_directory == "" {
        // default cache directory to XDG_CACHE_HOME if it exists, otherwise ~/.cache (and expand the ~ later)
        cache_directory_env_var := getenv("XDG_CACHE_HOME");
        cache_directory := ifx cache_directory_env_var then to_string(cache_directory_env_var) else "~/.cache";
        album_cover_directory = sprint("%/grishcompoop/covers", cache_directory);
    }
    config.album_cover_directory, success = expand_path(album_cover_directory);
    if !success {
        log("Failed to expand album cover directory '%'", album_cover_directory, flags=.ERROR);
        free(album_cover_directory);
    }

    mpd_library_directory := config.mpd_library_directory;
    config.mpd_library_directory, success = expand_path(mpd_library_directory);
    if !success {
        log("Failed to expand MPD library directory '%'", mpd_library_directory, flags=.ERROR);
        free(mpd_library_directory);
    }

    return config, config_file_loaded;
}

#scope_file

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
        MAX_LOG_SIZE;
        LOG_LEVEL;
        MPD_LIBRARY_DIRECTORY;
        ALBUM_COVER_DIRECTORY;
    } = ---;

    parsed_key := builder_to_string(*builder);
    if parsed_key == {
      case "mpd_host";
        config_key = .MPD_HOST;
      case "mpd_port";
        config_key = .MPD_PORT;
      case "max_log_size";
        config_key = .MAX_LOG_SIZE;
      case "log_level";
        config_key = .LOG_LEVEL;
      case "mpd_library_directory";
        config_key = .MPD_LIBRARY_DIRECTORY;
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

      case .MAX_LOG_SIZE;

        success: bool;
        max_log_size: int;
        remainder: string;
        max_log_size, success, remainder = to_integer(<<text);
        if !success  return New_Error(original_count - text.count + 1, tprint("Error parsing max_log_size value as integer"));

        if max_log_size < 1 || max_log_size > 4294967295 { // we accept a u32 because libmpdclient does (u16 is usually the max range)
            return New_Error(original_count - text.count + 1, tprint("Invalid value for max_log_size"));
        }
        <<text = remainder;
        config.max_log_size = cast,no_check(u32)max_log_size;

      case .LOG_LEVEL;
        reset(*builder);
        while s := <<text {
            if is_space(s[0]) break;
            append(*builder, s[0]);
            advance(text, 1);
        }
        log_level := builder_to_string(*builder);
        if log_level == {
          case "normal";
            config.log_level = .NORMAL;
          case "verbose";
            config.log_level = .VERBOSE;
          case "very_verbose";
            config.log_level = .VERY_VERBOSE;
        }

      case .ALBUM_COVER_DIRECTORY;
        reset(*builder);
        while s := <<text {
            if is_space(s[0]) break;
            append(*builder, s[0]);
            advance(text, 1);
        }
        config.album_cover_directory = builder_to_string(*builder);

      case .MPD_LIBRARY_DIRECTORY;
        reset(*builder);
        while s := <<text {
            if is_space(s[0]) break;
            append(*builder, s[0]);
            advance(text, 1);
        }
        config.mpd_library_directory = builder_to_string(*builder);
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

is_newline :: inline (c : u8) -> bool {
    return c == #char "\r" || c == #char "\n";
}
