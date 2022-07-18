#scope_file

#import "Basic";
#import "Math";

#import "common";

Simp  :: #import "Simp";

log_data :: Log_Data.{"log_view"};

#scope_export

event_loop :: (font: *Simp.Dynamic_Font, header_bottom: int) {
    items_in_page := (header_bottom - 2 * Y_MARGIN_SIZE) / (font.character_height + TEXT_PADDING_Y);
    x := X_MARGIN_SIZE;
    y := header_bottom - Y_PADDING_BELOW_HEADER;
    for i: max(0, log_history.entries.count-items_in_page-1)..log_history.entries.count-1 {
        Simp.draw_text(font, x, y, log_history.entries[(log_history.first_entry + i) % log_history.entries.count], rgba(1,1,1,1));
        y -= TEXT_PADDING_Y + font.character_height;
    }
}
