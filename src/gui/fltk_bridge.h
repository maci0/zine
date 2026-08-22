#ifndef FLTK_BRIDGE_H
#define FLTK_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Initialization */
void fltk_init(int w, int h, const char* title);
void fltk_show_window(void);
void fltk_run_check(void);  /* non-blocking event pump (Fl::check()) */

/* Window chrome */
void fltk_set_title(const char* title);
void fltk_resize_window(int x, int y, int w, int h);

/* Framebuffer display */
void fltk_set_framebuf(const unsigned char* rgba, int w, int h);
void fltk_redraw(void);

/* Menu bar */
void fltk_set_menu_json(const char* json, int len);
void fltk_enable_menu_item(int id, int enabled);
void fltk_check_menu_item(int id, int checked);

/* Dialogs */
void fltk_alert(const char* title, const char* text);

/* Modal dialog: create window, add items, then finish+show */
void fltk_show_dialog(const char* title, int cx, int cy);
void fltk_add_dialog_item(const char* cls, int id, int x, int y, int cx, int cy,
                          const char* text);
void fltk_finish_dialog(void);
void fltk_close_dialog(void);

/* Controls (buttons, labels, status bar, progress bar) */
void fltk_add_control(const char* cls, int id, int x, int y, int w, int h,
                      unsigned style, const char* text);
void fltk_update_control_text(int id, const char* text);
void fltk_update_control_value(int id, int value);
void fltk_set_control_checked(int id, int checked);
void fltk_set_listbox_items(int id, const char* items);
void fltk_set_control_color(int id, unsigned color);
void fltk_open_color_dialog(unsigned initial);
void fltk_update_control_range(int id, int min, int max);

/* Context menu: items JSON like [{"id":1,"text":"Open","separator":false,...}] */
void fltk_show_context_menu(int x, int y, const char* items_json, int len);

/* Clipboard + window icon */
void fltk_set_clipboard(const char* text);
void fltk_set_icon(const unsigned char* png, int len);

/* File dialog */
typedef void (*fltk_file_cb)(const char* path, int cancelled);
void fltk_set_file_callback(fltk_file_cb cb);
void fltk_open_file_dialog(const char* filters, int is_save);

/* Font dialog (ChooseFont) */
typedef void (*fltk_font_cb)(const char* face, int size, int bold, int italic, int cancelled);
void fltk_set_font_callback(fltk_font_cb cb);
void fltk_open_font_dialog(const char* face, int size, int bold, int italic);

/* Print dialog (PrintDlg) */
typedef void (*fltk_print_cb)(int from_page, int to_page, int copies, int cancelled);
void fltk_set_print_callback(fltk_print_cb cb);
void fltk_open_print_dialog(int from_page, int to_page, int min_page, int max_page, int copies);

/* Find/Replace dialog (FindTextA / ReplaceTextA, modeless) */
typedef void (*fltk_find_cb)(const char* action, const char* find_text, const char* replace_text, int match_case, int search_down);
void fltk_set_find_callback(fltk_find_cb cb);
void fltk_open_find_dialog(const char* find_text, const char* replace_text, int is_replace);

/* Page Setup dialog (PageSetupDlg) */
typedef void (*fltk_pagesetup_cb)(int left, int top, int right, int bottom, int paper_w, int paper_h, int orientation, int cancelled);
void fltk_set_pagesetup_callback(fltk_pagesetup_cb cb);
void fltk_open_page_setup_dialog(int left, int top, int right, int bottom, int paper_w, int paper_h, int orientation);

/* Edit / RichEdit control */
typedef void (*fltk_edit_text_cb)(const char* text);
void fltk_set_edit_text_callback(fltk_edit_text_cb cb);
void fltk_edit_show(int multiline);
void fltk_edit_resize(int x, int y, int w, int h);
void fltk_edit_set_text(const char* text);
void fltk_edit_set_sel(int start, int end);
void fltk_edit_replace_sel(const char* text);
void fltk_edit_insert_char(unsigned ch);
void fltk_edit_undo(void);
void fltk_edit_scroll_caret(void);

/* Threading */
void fltk_awake(void);      /* wake FLTK main thread from worker */
void fltk_lock(void);
void fltk_unlock(void);

/* Event callback — type is one of the FLTK_EVT_* constants below */
typedef void (*fltk_event_cb)(int type, int param1, int param2);
void fltk_set_event_callback(fltk_event_cb cb);

/* Event types passed to the callback */
#define FLTK_EVT_KEY_DOWN     1
#define FLTK_EVT_KEY_UP       2
#define FLTK_EVT_CLOSE        3
#define FLTK_EVT_RESIZE       4
#define FLTK_EVT_MENU_CMD     5
#define FLTK_EVT_LDOWN        6
#define FLTK_EVT_LUP          7
#define FLTK_EVT_RDOWN        8
#define FLTK_EVT_RUP          9
#define FLTK_EVT_MOVE         10
#define FLTK_EVT_WHEEL        11
#define FLTK_EVT_COLOR_SEL    12
#define FLTK_EVT_FONT_SEL     13

#ifdef __cplusplus
}
#endif

#endif /* FLTK_BRIDGE_H */
