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

#ifdef __cplusplus
}
#endif

#endif /* FLTK_BRIDGE_H */
