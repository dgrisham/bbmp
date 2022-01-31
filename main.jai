#import "Basic";

MPD :: #import "libmpdclient";

Command :: enum {
    TOGGLE_PAUSE;
    VOLUME_UP;
    VOLUME_DOWN;
    NEXT;
    PREVIOUS;
}

main :: () {

    args := get_command_line_arguments();
    defer array_free(args);

    if args.count != 2 { print("usage: ./main <arg>\n"); exit(1); }
    command: Command;
    if args[1] == {
        case "toggle_pause";
            command = .TOGGLE_PAUSE;
        case "volume_up";
            command = .VOLUME_UP;
        case "volume_down";
            command = .VOLUME_DOWN;
        case "next_song";
            command = .NEXT;
        case "previous_song";
            command = .PREVIOUS;
    }

    connection : *MPD.connection = MPD.connection_new(null, 0, 0);

    // error handling
    if connection == null {
        print("Out of memory\n");
        exit(1);
    }
    error := check_connection_errors(connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
    }

    print("Successfully initialized MPD connection\n");

    VOLUME_CHANGE_AMOUNT :: 5;

    if #complete command == {
      case .TOGGLE_PAUSE;
        MPD.run_toggle_pause(connection);
      case .VOLUME_UP;
        MPD.run_change_volume(connection, VOLUME_CHANGE_AMOUNT);
      case .VOLUME_DOWN;
        MPD.run_change_volume(connection, -1 * VOLUME_CHANGE_AMOUNT);
      case .NEXT;
        MPD.run_next(connection);
      case .PREVIOUS;
        MPD.run_previous(connection);
    }
    error = check_connection_errors(connection);
    if error {
        print("% error: code=%, message='%', recovered=%\n", error.type, error.code, error.message, error.recovered);
        if !error.recovered exit(1);
    }

    // close the connection and free memory
    MPD.connection_free(connection);
}

Error_Type :: enum {
    SERVER;
    CLIENT;
}

Error :: struct {
    code: MPD.server_error;
    message: string;
    recovered: bool;
    type: Error_Type;
}

Server_Error :: struct {
    using _error: Error;
    type = .SERVER;
}

Client_Error :: struct {
    using _error: Error;
    type = .CLIENT;
}

check_connection_errors :: (connection: *MPD.connection) -> *Error {
	error_code := MPD.connection_get_error(connection);
	if (error_code != .SUCCESS) {
		msg := to_string(MPD.connection_get_error_message(connection));

		if error_code == .SERVER {
    		error := New(Server_Error);
			error.code      = MPD.connection_get_server_error(connection);
			error.recovered = MPD.connection_clear_error(connection);
			return error;
		} else {
    		error := New(Client_Error);
    		error.message   = msg;
			error.recovered = MPD.connection_clear_error(connection);
			return error;
		}
	}

	return null;
}
