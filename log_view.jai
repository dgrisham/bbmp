#scope_file

#import "Basic";
#import "Hash_Table";
#import "Math";

#import "common";

Input  :: #import "Input";
Simp   :: #import "Simp";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_search_query_key_pressed: Key;
search_query_key_pressed_on_frame: Table(Key, u64);

search_query: Search_Query;

inputting_search_query := false;

cursor: struct {
    position := 0;
};

follow_log := true;

log_data :: Log_Data.{"log_view", false};

#scope_export

event_loop :: (font: *Simp.Dynamic_Font, frame: u64, display_width: s32, header_bottom: int) {

    context.logger_data = *log_data;

    move_cursor_down :: () #expand {
        `cursor.position += 1;
    }
    move_cursor_up :: () #expand {
        `cursor.position -= 1;
    }

    move_cursor_half_page_down :: () #expand {
        `cursor.position += max_items_in_page / 2;
    }
    move_cursor_half_page_up :: () #expand {
        `cursor.position -= max_items_in_page / 2;
    }

    max_items_in_page := (header_bottom - Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);

    if follow_log {
        for Input.events_this_frame {
            if it.type == {
              case .KEYBOARD;
                if it.key_pressed {
                    if it.key_code == {
                      case KEY_F;
                        if it.shift_pressed {
                            follow_log = false;
                            cursor.position = log_history.entries.count - max_items_in_page / 2 + 1;
                        }
                        break it;
                    }
                }
            }
        }
    } else {
        for Input.events_this_frame {
            if it.type == .KEYBOARD && it.key_pressed {
                if it.ctrl_pressed {
                    if it.key_code == {

                      case KEY_D;
                        table_set(*key_pressed_on_frame, .CTRL_D, frame);
                        last_key_pressed = .CTRL_D;
                        move_cursor_half_page_down();
                        break it;
                      case KEY_U;
                        table_set(*key_pressed_on_frame, .CTRL_U, frame);
                        last_key_pressed = .CTRL_U;
                        move_cursor_half_page_up();
                        break it;

                    }
                } else {
                    if it.key_code == {

                      case KEY_J;
                        table_set(*key_pressed_on_frame, .J, frame);
                        last_key_pressed = .J;
                        move_cursor_down();
                        break it;
                      case KEY_K;
                        table_set(*key_pressed_on_frame, .K, frame);
                        last_key_pressed = .K;
                        move_cursor_up();
                        break it;

                      case KEY_G;
                        if it.shift_pressed {
                            cursor.position = log_history.entries.count - 1;
                        } else {
                            cursor.position = 0;
                        }
                        break it;

                      case KEY_F;
                        if it.shift_pressed {
                            follow_log = true;
                        }
                        break it;
                      case .ESCAPE;
                        follow_log = true;
                        break it;

                    }
                }
            }
        }

        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       move_cursor_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       move_cursor_up();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  move_cursor_half_page_down();
        if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  move_cursor_half_page_up();
    }

    if cursor.position < 0 {
        cursor.position = 0;
    } else if cursor.position > log_history.entries.count - 1 {
        cursor.position = log_history.entries.count - 1;
    }

    /*******
    * draw *
    *******/

    index_start, max_entries_to_show: int;
    if follow_log {
        index_start = max(0, log_history.entries.count-1 - max_items_in_page);
    } else {
        index_start = max(0, min(log_history.entries.count-1 - max_items_in_page, cursor.position - max_items_in_page / 2));
    }
    max_entries_to_show = min(max_items_in_page, log_history.entries.count);

    x := X_MARGIN_SIZE;
    y := header_bottom;

    i := 0; // keep track of the next log index to check
    entries_shown := 0; // keep track of the number of entries we've shown, since we might skip some based on verbosity
    while entries_shown <= max_entries_to_show && i < log_history.entries.count {
        log_entry := log_history.entries[(log_history.first_entry + index_start + i) % log_history.entries.count];
        i += 1;
        if log_entry.flags & .VERBOSE_ONLY && config.log_level < .VERBOSE {
            continue;
        }
        if log_entry.flags & .VERY_VERBOSE_ONLY && config.log_level < .VERY_VERBOSE {
            continue;
        }

        color := rgba(1,1,1,1); // default to white
        if log_entry.flags & .ERROR { // errors in red
            color = rgba(1,0,0,1);
        } else if log_entry.flags & .WARNING { // warnings in yellow
            color = rgba(1,0.9,0,1);
        }
        if !follow_log && (index_start + entries_shown) == cursor.position {
            Simp.set_shader_for_color();
            Simp.immediate_quad(cast(float)x - 10, cast(float)y - 5, cast(float)x + cast(s32)display_width, cast(float)y + font.character_height, color);
            Simp.draw_text(font, x, y, log_entry.message, rgba(0,0,0,1));
        } else {
            Simp.draw_text(font, x, y, log_entry.message, color);
        }

        y -= TEXT_PADDING_Y + font.character_height;
        entries_shown += 1;
    }
}
