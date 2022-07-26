#scope_file

#import "Basic";
#import "Hash_Table";
#import "Math";
#import "Unicode";

#import "common";
#import "config";

Input :: #import "Input";
Simp  :: #import "Simp";

last_key_pressed: Key;
key_pressed_on_frame: Table(Key, u64);

last_field_input_key_pressed: Key;
field_input_key_pressed_on_frame: Table(Key, u64);

cursor: struct {
    position            := 0;
    text_input_position := 0;
};

log_data :: Log_Data.{"config_editor", false};

ORDERED_CONFIG_KEYS :: string.[
    "mpd_host",
    "mpd_port",
    "max_log_size",
    "log_level",
    "album_cover_directory",
    "mpd_library_directory",
];

input_config: Table(string, string);

inputting_config_value := false;

ENABLE_CONFIG_EDITOR :: false;

#scope_export

// should be called after the user's config is loaded
load :: () {
    // initialize input text boxes to the originally loaded config
    table_set(*input_config, "mpd_host",              copy_string(config.mpd_host));
    table_set(*input_config, "mpd_port",              sprint("%", config.mpd_port));
    table_set(*input_config, "log_level",             sprint("%", config.log_level));
    table_set(*input_config, "max_log_size",          sprint("%", config.max_log_size));
    table_set(*input_config, "album_cover_directory", copy_string(config.album_cover_directory));
    table_set(*input_config, "mpd_library_directory", copy_string(config.mpd_library_directory));
}

event_loop :: (font: *Simp.Dynamic_Font, frame: u64, display_width: s32, header_bottom: int) -> bool {

    original_logger_data := context.logger_data;
    context.logger_data = *log_data;
    defer context.logger_data = original_logger_data;

    max_items_in_page := (header_bottom - Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);

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

    backspace_config_value :: () {
        key := ORDERED_CONFIG_KEYS[cursor.position];
        value_ptr := table_find_pointer(*input_config, key);
        assert(value_ptr != null);
        backspace_one_character(value_ptr);
        cursor.text_input_position -= 1;

        backspace_one_character :: (s: *string) {
            if <<s == "" return;

            i := 0;
            bytes_in_last_utf8 := 0;
            is_space := false;
            while i < s.count {
                bytes_in_last_utf8 = 1 + trailingBytesForUTF8[s.data[i]];
                i += bytes_in_last_utf8;
            }
            is_space = bytes_in_last_utf8 == 1 && (<<s)[s.count - 1] == SPACE;
            s.count -= bytes_in_last_utf8;
        }
    }

    #if ENABLE_CONFIG_EDITOR {
        if !inputting_config_value {
            for Input.events_this_frame {
                if it.type == {
                  case .KEYBOARD;
                    if it.key_pressed {
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

                          case KEY_D;
                            if it.ctrl_pressed {
                                table_set(*key_pressed_on_frame, .CTRL_D, frame);
                                last_key_pressed = .CTRL_D;
                                move_cursor_half_page_down();
                            }
                            break it;
                          case KEY_U;
                            if it.ctrl_pressed {
                                table_set(*key_pressed_on_frame, .CTRL_U, frame);
                                last_key_pressed = .CTRL_U;
                                move_cursor_half_page_up();
                            }
                            break it;

                          case KEY_G;
                            if it.shift_pressed {
                                cursor.position = ORDERED_CONFIG_KEYS.count - 1;
                            } else {
                                cursor.position = 0;
                            }
                            break it;

                          case KEY_I; #through;
                          case .ENTER;
                            key := ORDERED_CONFIG_KEYS[cursor.position];
                            value_ptr := table_find_pointer(*input_config, key);
                            assert(value_ptr != null);
                            cursor.text_input_position = value_ptr.count;
                            inputting_config_value = true;
                            break it;
                        }
                    }
                }
            }

            if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .J)       move_cursor_down();
            if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .K)       move_cursor_up();
            if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_D)  move_cursor_half_page_down();
            if key_held_passed_threshold(key_pressed_on_frame, last_key_pressed, frame, .CTRL_U)  move_cursor_half_page_up();
        } else {
            for Input.events_this_frame {
                if it.type == {

                  case .TEXT_INPUT;
                    key := ORDERED_CONFIG_KEYS[cursor.position];
                    value_ptr := table_find_pointer(*input_config, key);
                    assert(value_ptr != null);
                    append_utf32_to_string(value_ptr, it.utf32);
                    cursor.text_input_position += 1;
                    break it;

                  case .KEYBOARD;
                    if it.key_pressed {
                        if it.key_code == {

                          case .BACKSPACE;
                            last_field_input_key_pressed = .BACKSPACE;
                            table_set(*field_input_key_pressed_on_frame, .BACKSPACE, frame);
                            backspace_config_value();
                            break it;

                          case KEY_U;
                            if it.ctrl_pressed {
                                last_field_input_key_pressed = .CTRL_U;
                                value_ptr := table_find_pointer(*input_config, ORDERED_CONFIG_KEYS[cursor.position]);
                                assert(value_ptr != null);
                                value_ptr.count = 0;
                                cursor.text_input_position = 0;
                                break it;
                            }

                          case .ENTER; #through;
                          case .ESCAPE;
                            last_field_input_key_pressed = .ESCAPE;
                            inputting_config_value = false;
                            break it;
                        }
                    }
                }
            }

            if key_held_passed_threshold(field_input_key_pressed_on_frame, last_field_input_key_pressed, frame, .BACKSPACE) { backspace_config_value(); }
        }
    }

    if cursor.position < 0 {
        cursor.position = 0;
    } else if cursor.position > ORDERED_CONFIG_KEYS.count - 1 {
        cursor.position = ORDERED_CONFIG_KEYS.count - 1;
    }

    /*************
    * draw frame *
    *************/

    {
        display_column :: struct {
            width           : s32;
            entries         : [] Display_Text;
        };
        display_keys, display_values: display_column;

        {
            display_keys.width   = cast(s32)(0.25 * display_width);
            display_values.width = cast(s32)(0.5 * display_width);

            index_start := max(0, min(ORDERED_CONFIG_KEYS.count - max_items_in_page, cursor.position - max_items_in_page/ 2 + 1));
            index_end   := min(index_start + max_items_in_page, ORDERED_CONFIG_KEYS.count) - 1;

            display_keys.entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);
            display_values.entries = NewArray(index_end - index_start + 1, Display_Text, false, temp);

            selected_index := cursor.position;

            for i: index_start..index_end {
                key := ORDERED_CONFIG_KEYS[i];

                { // key
                    max_characters_in_column := display_keys.width / font.w_width - 2;
                    display_text: Display_Text;
                    display_text.text = create_temp_display_string_of_max_length(key, max_characters_in_column);
                    display_text.selected = selected_index == i;

                    display_keys.entries[i-index_start] = display_text;
                }

                { // value
                    value_ptr := table_find_pointer(*input_config, key);
                    assert(value_ptr != null);

                    max_characters_in_column := display_values.width / font.w_width - 2;
                    display_text: Display_Text;
                    if inputting_config_value {
                        display_text.text = create_temp_display_string_of_max_length_truncate_left(<<value_ptr, max_characters_in_column);
                    } else {
                        display_text.text = create_temp_display_string_of_max_length(<<value_ptr, max_characters_in_column);
                    }
                    display_text.selected = selected_index == i;

                    display_values.entries[i-index_start] = display_text;
                }
            }
        }

        {
            x_center := display_width / 2;
            y := header_bottom;
            for display_key: display_keys.entries {
                key_width := Simp.prepare_text(font, display_key.text);
                Simp.draw_prepared_text(font, x_center - key_width, y, rgba(1,1,1,1));

                Simp.draw_text(font, x_center, y, " = ", rgba(1,1,1,1));

                x := x_center + 3 * font.w_width;
                value := display_values.entries[it_index];
                #if ENABLE_CONFIG_EDITOR {
                    if value.selected {
                        if inputting_config_value {
                            value_width := Simp.prepare_text(font, value.text);
                            Simp.draw_prepared_text(font, x, y, rgba(1,1,1,1));

                            Simp.set_shader_for_color();
                            x_cursor_start := cast(float)x + value_width;
                            Simp.immediate_quad(x_cursor_start, cast(float)y - 5, x_cursor_start + font.w_width, cast(float)y + font.character_height, rgba(1,1,1,1));
                        } else {
                            Simp.set_shader_for_color();
                            Simp.immediate_quad(cast(float)x - 3, cast(float)y - 5, cast(float)x + display_values.width, cast(float)y + font.character_height, rgba(1,1,1,1));
                            Simp.draw_text(font, x, y, value.text, rgba(0,0,0,1));
                        }
                    } else {
                        Simp.draw_text(font, x, y, value.text, rgba(1,1,1,1));
                    }
                } else {
                    Simp.draw_text(font, x, y, value.text, rgba(1,1,1,1));
                }

                y -= TEXT_PADDING_Y + font.character_height;
            }
        }
    }

    return inputting_config_value;
}
