MPD :: #import "libmpdclient";

main :: () {
    conn : *MPD.connection = MPD.connection_new(null, 0, 0);

    // error handling
    if conn == null {
        print("Out of memory\n");
        exit(1);
    }
    if MPD.connection_get_error(conn) != .SUCCESS {
        print("error: %\n", mpd_get_error_message(conn));
        MPD.connection_free(conn);
        exit(1);
    }

    print("Successfully initialized MPD connection\n");

    // we can now use the connection
    MPD.run_toggle_pause(conn);

    // close the connection and free memory
    MPD.connection_free(conn);
}

mpd_get_error_message :: inline (c: *MPD.connection) -> string {
    return to_string(MPD.connection_get_error_message(c));
}

#import "Basic";
