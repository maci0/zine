/*
 * fltk_bridge.cpp — Minimal C-callable bridge to FLTK 1.3 for Zine
 *
 * This provides the subset of FLTK functionality needed by fltk_ui.zig:
 * window management, framebuffer blitting, menu bar, dialogs, and threading.
 */

#include <FL/Fl.H>
#include <FL/Fl_Double_Window.H>
#include <FL/Fl_Box.H>
#include <FL/Fl_Menu_Bar.H>
#include <FL/Fl_RGB_Image.H>
#include <FL/fl_ask.H>
#include <cstring>
#include <cstdlib>
#include <cstdio>

#include "fltk_bridge.h"

/* ───────────────────────────────────────────────── globals */

static Fl_Double_Window* g_window  = nullptr;
static Fl_Menu_Bar*      g_menubar = nullptr;
static Fl_Box*           g_canvas  = nullptr;
static Fl_RGB_Image*     g_image   = nullptr;
static unsigned char*    g_imgbuf  = nullptr;   /* owned copy of RGBA pixels */
static int               g_img_w   = 0;
static int               g_img_h   = 0;

static fltk_event_cb     g_event_cb = nullptr;

/* Menubar height in pixels */
static const int MENUBAR_H = 25;

/* ───────────────────────────────────────────── helpers */

/* Map FLTK key codes to Win32 VK codes */
static int fltk_key_to_vk(int key) {
    /* Printable ASCII maps directly for letters/digits */
    if (key >= 'a' && key <= 'z') return key - 'a' + 0x41;
    if (key >= 'A' && key <= 'Z') return key;               /* already VK */
    if (key >= '0' && key <= '9') return key;
    if (key == ' ')  return 0x20;

    switch (key) {
        case FL_Escape:    return 0x1B;
        case FL_BackSpace: return 0x08;
        case FL_Tab:       return 0x09;
        case FL_Enter:     return 0x0D;
        case FL_Delete:    return 0x2E;
        case FL_Home:      return 0x24;
        case FL_End:       return 0x23;
        case FL_Page_Up:   return 0x21;
        case FL_Page_Down: return 0x22;
        case FL_Left:      return 0x25;
        case FL_Up:        return 0x26;
        case FL_Right:     return 0x27;
        case FL_Down:      return 0x28;
        case FL_Shift_L:   case FL_Shift_R:   return 0x10;
        case FL_Control_L: case FL_Control_R: return 0x11;
        case FL_Alt_L:     case FL_Alt_R:     return 0x12;
        default: break;
    }
    /* F1..F12 */
    if (key >= FL_F + 1 && key <= FL_F + 12) return 0x70 + (key - FL_F - 1);
    return 0;
}

/* ───────────────────────────────────────── custom window */

/*
 * Subclass Fl_Double_Window to intercept keyboard and window events
 * and forward them to the Zig callback.
 */
class ZineWindow : public Fl_Double_Window {
public:
    ZineWindow(int w, int h, const char* t = nullptr)
        : Fl_Double_Window(w, h, t) {}

    int handle(int event) override {
        switch (event) {
            case FL_KEYBOARD: {
                int vk = fltk_key_to_vk(Fl::event_key());
                if (vk && g_event_cb) g_event_cb(FLTK_EVT_KEY_DOWN, vk, 0);
                return 1;
            }
            case FL_KEYUP: {
                int vk = fltk_key_to_vk(Fl::event_key());
                if (vk && g_event_cb) g_event_cb(FLTK_EVT_KEY_UP, vk, 0);
                return 1;
            }
            case FL_CLOSE:
                /* Don't actually close — let Zig decide */
                if (g_event_cb) g_event_cb(FLTK_EVT_CLOSE, 0, 0);
                return 1;
            default:
                break;
        }
        return Fl_Double_Window::handle(event);
    }

    void resize(int x, int y, int w, int h) override {
        Fl_Double_Window::resize(x, y, w, h);
        /* Re-layout: menubar at top, canvas fills the rest */
        if (g_menubar) g_menubar->resize(0, 0, w, MENUBAR_H);
        if (g_canvas)  g_canvas->resize(0, MENUBAR_H, w, h - MENUBAR_H);
        if (g_event_cb) {
            int cw = w;
            int ch = h - MENUBAR_H;
            g_event_cb(FLTK_EVT_RESIZE, cw, ch);
        }
    }
};

/* ───────────────────────────────────────── menu callback */

static void menu_cb(Fl_Widget*, void* data) {
    long id = (long)data;
    if (g_event_cb) g_event_cb(FLTK_EVT_MENU_CMD, (int)id, 0);
}

/* ─────────────────────────────────── public C API impl */

extern "C" {

void fltk_init(int w, int h, const char* title) {
    Fl::lock();   /* enable FLTK multithreading */

    /* Win2K-like color scheme */
    Fl::set_color(FL_BACKGROUND_COLOR, 0xD4, 0xD0, 0xC8);
    Fl::set_color(FL_BACKGROUND2_COLOR, 0xFF, 0xFF, 0xFF);
    Fl::set_color(FL_FOREGROUND_COLOR, 0x00, 0x00, 0x00);
    Fl::set_color(FL_SELECTION_COLOR, 0x0A, 0x24, 0x6A);
    Fl::set_color(FL_INACTIVE_COLOR, 0x80, 0x80, 0x80);

    Fl::scheme("none");  /* classic look, closest to Win2K */

    g_window = new ZineWindow(w, h + MENUBAR_H, title);
    g_window->color(FL_BACKGROUND_COLOR);

    g_menubar = new Fl_Menu_Bar(0, 0, w, MENUBAR_H);
    g_menubar->textsize(12);

    g_canvas = new Fl_Box(0, MENUBAR_H, w, h);
    g_canvas->color(FL_BLACK);
    g_canvas->box(FL_FLAT_BOX);

    g_window->end();
    g_window->resizable(g_canvas);
}

void fltk_show_window(void) {
    if (g_window) g_window->show();
}

void fltk_run_check(void) {
    Fl::check();
}

void fltk_set_title(const char* title) {
    if (g_window) g_window->copy_label(title);
}

void fltk_resize_window(int x, int y, int w, int h) {
    if (g_window) g_window->resize(x, y, w, h + MENUBAR_H);
}

void fltk_set_framebuf(const unsigned char* rgba, int w, int h) {
    int sz = w * h * 4;
    /* Reallocate pixel buffer if size changed */
    if (w != g_img_w || h != g_img_h) {
        free(g_imgbuf);
        g_imgbuf = (unsigned char*)malloc(sz);
        g_img_w = w;
        g_img_h = h;
    }
    if (!g_imgbuf) return;

    /* Copy RGBA data — FLTK Fl_RGB_Image expects RGBA with depth=4 */
    memcpy(g_imgbuf, rgba, sz);

    /* Replace the image on the canvas */
    delete g_image;
    g_image = new Fl_RGB_Image(g_imgbuf, w, h, 4);
    if (g_canvas) {
        g_canvas->image(g_image);
        g_canvas->redraw();
    }
}

void fltk_redraw(void) {
    if (g_window) g_window->redraw();
}

/*
 * Minimal JSON menu parser.
 *
 * Expected format:
 *   {"type":"set_menu","items":[
 *     {"label":"&File","children":[
 *       {"label":"&New","id":40001},
 *       {"label":"-"},            // separator
 *       {"label":"E&xit","id":40002}
 *     ]},
 *     ...
 *   ]}
 *
 * We build Fl_Menu_Bar paths like "File/New" with menu_cb and user data = id.
 */
void fltk_set_menu_json(const char* json, int len) {
    if (!g_menubar || !json || len <= 0) return;
    g_menubar->clear();

    /* Simple character-by-character state machine parser */
    /* We look for "label":"..." and "id":NNN patterns */
    /* Track nesting to build path strings like "File/New" */

    char path[512] = {0};
    int path_depth = 0;
    char parent_labels[8][128];  /* up to 8 levels deep */
    memset(parent_labels, 0, sizeof(parent_labels));

    int brace_depth = 0;
    int bracket_depth = 0;
    int in_children = 0;

    /* State for current object being parsed */
    char cur_label[128] = {0};
    int  cur_id = -1;
    int  has_children = 0;

    int i = 0;
    while (i < len) {
        if (json[i] == '{') {
            brace_depth++;
            /* Reset current object state */
            cur_label[0] = 0;
            cur_id = -1;
            has_children = 0;
            i++;
        } else if (json[i] == '}') {
            brace_depth--;

            /* When closing an object that has a label, add it to the menu */
            if (cur_label[0] != 0) {
                /* Remove '&' accelerator markers — FLTK uses '&' differently */
                char clean_label[128] = {0};
                int ci = 0;
                for (int j = 0; cur_label[j] && ci < 126; j++) {
                    if (cur_label[j] != '&') clean_label[ci++] = cur_label[j];
                }
                clean_label[ci] = 0;

                /* Build full path */
                path[0] = 0;
                for (int d = 0; d < path_depth; d++) {
                    if (d > 0) strcat(path, "/");
                    strcat(path, parent_labels[d]);
                }
                if (path_depth > 0) strcat(path, "/");

                if (clean_label[0] == '-') {
                    /* Separator */
                    /* FLTK doesn't have a direct separator — we skip or could
                       add a deactivated empty item. For now, skip. */
                } else if (has_children) {
                    /* This is a submenu parent — don't add as item,
                       children will use it as path prefix */
                } else {
                    /* Leaf menu item */
                    char full_path[640] = {0};
                    snprintf(full_path, sizeof(full_path), "%s%s", path, clean_label);
                    int menu_id = (cur_id >= 0) ? cur_id : 0;
                    g_menubar->add(full_path, 0, menu_cb, (void*)(long)menu_id);
                }
            }
            i++;
        } else if (json[i] == '[') {
            bracket_depth++;
            /* If we just saw "children", push the current label as parent */
            if (in_children) {
                if (path_depth < 8 && cur_label[0] != 0) {
                    /* Remove '&' from parent label too */
                    int ci = 0;
                    for (int j = 0; cur_label[j] && ci < 126; j++) {
                        if (cur_label[j] != '&')
                            parent_labels[path_depth][ci++] = cur_label[j];
                    }
                    parent_labels[path_depth][ci] = 0;
                    path_depth++;
                }
                in_children = 0;
            }
            i++;
        } else if (json[i] == ']') {
            bracket_depth--;
            if (path_depth > 0) path_depth--;
            i++;
        } else if (json[i] == '"') {
            /* Parse a string */
            i++;
            char key[64] = {0};
            int ki = 0;
            while (i < len && json[i] != '"' && ki < 62) {
                key[ki++] = json[i++];
            }
            key[ki] = 0;
            if (i < len) i++; /* skip closing quote */

            /* Check if next is ':' (this is a key) */
            /* Skip whitespace */
            while (i < len && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r')) i++;

            if (i < len && json[i] == ':') {
                i++; /* skip ':' */
                /* Skip whitespace */
                while (i < len && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r')) i++;

                if (strcmp(key, "label") == 0 && i < len && json[i] == '"') {
                    /* Parse string value */
                    i++; /* skip opening quote */
                    int li = 0;
                    while (i < len && json[i] != '"' && li < 126) {
                        if (json[i] == '\\' && i + 1 < len) {
                            i++; /* skip backslash, take next char */
                        }
                        cur_label[li++] = json[i++];
                    }
                    cur_label[li] = 0;
                    if (i < len) i++; /* skip closing quote */
                } else if (strcmp(key, "id") == 0) {
                    /* Parse integer value */
                    cur_id = 0;
                    int neg = 0;
                    if (i < len && json[i] == '-') { neg = 1; i++; }
                    while (i < len && json[i] >= '0' && json[i] <= '9') {
                        cur_id = cur_id * 10 + (json[i] - '0');
                        i++;
                    }
                    if (neg) cur_id = -cur_id;
                } else if (strcmp(key, "children") == 0) {
                    has_children = 1;
                    in_children = 1;
                    /* Don't advance — the '[' will be caught by the main loop */
                } else if (strcmp(key, "type") == 0) {
                    /* Skip the value (string) */
                    if (i < len && json[i] == '"') {
                        i++;
                        while (i < len && json[i] != '"') {
                            if (json[i] == '\\' && i + 1 < len) i++;
                            i++;
                        }
                        if (i < len) i++;
                    }
                } else {
                    /* Unknown key — skip value */
                    if (i < len && json[i] == '"') {
                        i++;
                        while (i < len && json[i] != '"') {
                            if (json[i] == '\\' && i + 1 < len) i++;
                            i++;
                        }
                        if (i < len) i++;
                    } else if (i < len && (json[i] >= '0' && json[i] <= '9')) {
                        while (i < len && json[i] >= '0' && json[i] <= '9') i++;
                    } else if (i < len && (json[i] == 't' || json[i] == 'f' || json[i] == 'n')) {
                        while (i < len && json[i] != ',' && json[i] != '}' && json[i] != ']') i++;
                    }
                }
            }
            /* If not followed by ':', this was a standalone string value — already consumed */
        } else {
            i++;
        }
    }

    g_menubar->redraw();
}

void fltk_enable_menu_item(int id, int enabled) {
    if (!g_menubar) return;
    /* Search through menu items for matching user data (id) */
    for (int i = 0; i < g_menubar->size(); i++) {
        const Fl_Menu_Item* item = &g_menubar->menu()[i];
        if (item->label() && (long)item->user_data() == id) {
            /* Can't directly modify const menu — use mode() */
            if (enabled) {
                g_menubar->mode(i, g_menubar->mode(i) & ~FL_MENU_INACTIVE);
            } else {
                g_menubar->mode(i, g_menubar->mode(i) | FL_MENU_INACTIVE);
            }
            break;
        }
    }
}

void fltk_check_menu_item(int id, int checked) {
    if (!g_menubar) return;
    for (int i = 0; i < g_menubar->size(); i++) {
        const Fl_Menu_Item* item = &g_menubar->menu()[i];
        if (item->label() && (long)item->user_data() == id) {
            if (checked) {
                g_menubar->mode(i, g_menubar->mode(i) | FL_MENU_TOGGLE | FL_MENU_VALUE);
            } else {
                g_menubar->mode(i, (g_menubar->mode(i) | FL_MENU_TOGGLE) & ~FL_MENU_VALUE);
            }
            break;
        }
    }
}

void fltk_alert(const char* title, const char* text) {
    fl_message_title(title);
    fl_alert("%s", text);
}

void fltk_awake(void) {
    Fl::awake();
}

void fltk_lock(void) {
    Fl::lock();
}

void fltk_unlock(void) {
    Fl::unlock();
}

void fltk_set_event_callback(fltk_event_cb cb) {
    g_event_cb = cb;
}

}  /* extern "C" */
