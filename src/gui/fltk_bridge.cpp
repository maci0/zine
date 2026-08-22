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
static unsigned char*    g_imgbuf  = nullptr;   /* owned copy of BGRA pixels */
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
            case FL_PUSH: {
                int ex = Fl::event_x();
                int ey = Fl::event_y() - MENUBAR_H;
                if (ey < 0) ey = 0;
                int btn = Fl::event_button();
                if (g_event_cb) {
                    if (btn == 3) g_event_cb(FLTK_EVT_RDOWN, ex, ey);
                    else g_event_cb(FLTK_EVT_LDOWN, ex, ey);
                }
                return 1;
            }
            case FL_RELEASE: {
                int ex = Fl::event_x();
                int ey = Fl::event_y() - MENUBAR_H;
                if (ey < 0) ey = 0;
                int btn = Fl::event_button();
                if (g_event_cb) {
                    if (btn == 3) g_event_cb(FLTK_EVT_RUP, ex, ey);
                    else g_event_cb(FLTK_EVT_LUP, ex, ey);
                }
                return 1;
            }
            case FL_DRAG:
            case FL_MOVE: {
                int ex = Fl::event_x();
                int ey = Fl::event_y() - MENUBAR_H;
                if (ey < 0) ey = 0;
                if (g_event_cb) g_event_cb(FLTK_EVT_MOVE, ex, ey);
                return 1;
            }
            case FL_MOUSEWHEEL: {
                /* Win32: positive delta = wheel away from user (up). FLTK's
                   event_dy is negative when scrolling up. One notch = 120. */
                int dy = Fl::event_dy();
                int delta = (dy < 0) ? 120 : -120;
                if (g_event_cb) g_event_cb(FLTK_EVT_WHEEL, delta, 0);
                return 1;
            }
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
    /* Reject unreasonable dimensions to prevent integer overflow in w*h*4 */
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return;
    size_t sz = (size_t)w * (size_t)h * 4;
    /* Reallocate pixel buffer if size changed */
    if (w != g_img_w || h != g_img_h) {
        free(g_imgbuf);
        g_imgbuf = (unsigned char*)malloc(sz);
        g_img_w = w;
        g_img_h = h;
    }
    if (!g_imgbuf) return;

    /* Copy raw pixel data — the source is BGRA but FLTK Fl_RGB_Image
       with depth=4 interprets it as RGBA, so red and blue appear swapped.
       This is acceptable for the current debug/preview use case. */
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

    int in_children = 0;

    /* State for current object being parsed */
    char cur_label[128] = {0};
    int  cur_id = -1;
    int  has_children = 0;

    int i = 0;
    while (i < len) {
        if (json[i] == '{') {
            /* Reset current object state */
            cur_label[0] = 0;
            cur_id = -1;
            has_children = 0;
            i++;
        } else if (json[i] == '}') {

            /* When closing an object that has a label, add it to the menu */
            if (cur_label[0] != 0) {
                /* Remove '&' accelerator markers — FLTK uses '&' differently */
                char clean_label[128] = {0};
                int ci = 0;
                for (int j = 0; cur_label[j] && ci < 126; j++) {
                    if (cur_label[j] != '&') clean_label[ci++] = cur_label[j];
                }
                clean_label[ci] = 0;

                /* Build full path using safe snprintf */
                path[0] = 0;
                {
                    int ppos = 0;
                    for (int d = 0; d < path_depth && ppos < (int)sizeof(path) - 1; d++) {
                        if (d > 0 && ppos < (int)sizeof(path) - 1)
                            ppos += snprintf(path + ppos, sizeof(path) - ppos, "/");
                        ppos += snprintf(path + ppos, sizeof(path) - ppos, "%s", parent_labels[d]);
                    }
                    if (path_depth > 0 && ppos < (int)sizeof(path) - 1)
                        snprintf(path + ppos, sizeof(path) - ppos, "/");
                }

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

/* ───────────────────────────────────────── controls */

#include <FL/Fl_Button.H>
#include <FL/Fl_Check_Button.H>
#include <FL/Fl_Round_Button.H>
#include <FL/Fl_Hold_Browser.H>
#include <FL/Fl_Choice.H>
#include <FL/Fl_Tabs.H>
#include <FL/Fl_Group.H>
#include <FL/Fl_Color_Chooser.H>
#include <FL/Fl_Progress.H>
#include <FL/Fl_Menu_Button.H>
#include <FL/Fl_Slider.H>
#include <FL/Fl_Spinner.H>
#include <FL/Fl_PNG_Image.H>
#include <cstdint>

/* Control registry: Win32 control id -> FLTK widget */
struct CtrlEntry {
    int id;
    Fl_Widget* widget;
};
static CtrlEntry g_ctrls[128];
static int g_ctrl_count = 0;

static Fl_Widget* find_ctrl(int id) {
    for (int i = 0; i < g_ctrl_count; i++) {
        if (g_ctrls[i].id == id) return g_ctrls[i].widget;
    }
    return nullptr;
}

static void register_ctrl(int id, Fl_Widget* w) {
    if (g_ctrl_count < 128) {
        g_ctrls[g_ctrl_count].id = id;
        g_ctrls[g_ctrl_count].widget = w;
        g_ctrl_count++;
    }
}

/* Strip Win32 '&' accelerator markers for display */
static void strip_accel(char* out, const char* in, size_t cap) {
    size_t o = 0;
    for (size_t i = 0; in[i] && o + 1 < cap; i++) {
        if (in[i] == '&' && in[i+1] == '&') { out[o++] = '&'; i++; }
        else if (in[i] == '&') { /* skip */ }
        else out[o++] = in[i];
    }
    out[o] = 0;
}

void fltk_add_control(const char* cls, int id, int x, int y, int w, int h,
                      unsigned style, const char* text) {
    (void)style;
    if (!g_window) return;
    Fl_Widget* wid = find_ctrl(id);
    if (wid) { wid->show(); return; }

    char label[512];
    strip_accel(label, text ? text : "", sizeof(label));

    int cy = y + MENUBAR_H; /* below the menu bar */

    if (cls && strstr(cls, "Button")) {
        const unsigned bs_type = style & 0xF;
        Fl_Button* b;
        if (bs_type == 2 || bs_type == 3) {
            /* BS_CHECKBOX / BS_AUTOCHECKBOX */
            b = new Fl_Check_Button(x, cy, w, h, label[0] ? label : nullptr);
        } else if (bs_type == 4 || bs_type == 9) {
            /* BS_RADIOBUTTON / BS_AUTORADIOBUTTON */
            b = new Fl_Round_Button(x, cy, w, h, label[0] ? label : nullptr);
        } else {
            b = new Fl_Button(x, cy, w, h, label[0] ? label : nullptr);
        }
        b->callback([](Fl_Widget* wgt, void*) {
            if (g_event_cb) {
                /* Find the control id from the widget */
                int cid = 0;
                for (int i = 0; i < g_ctrl_count; i++) {
                    if (g_ctrls[i].widget == wgt) { cid = g_ctrls[i].id; break; }
                }
                g_event_cb(FLTK_EVT_MENU_CMD, cid, 0);
            }
        });
        wid = b;
    } else if (cls && strstr(cls, "SysTabControl32")) {
        Fl_Tabs* tabs = new Fl_Tabs(x, cy, w, h);
        wid = tabs;
    } else if (cls && strstr(cls, "SysListView32")) {
        Fl_Hold_Browser* lb = new Fl_Hold_Browser(x, cy, w, h);
        wid = lb;
    } else if (cls && strstr(cls, "SysTreeView32")) {
        Fl_Hold_Browser* tb = new Fl_Hold_Browser(x, cy, w, h);
        wid = tb;
    } else if (cls && strstr(cls, "ComboBox")) {
        Fl_Choice* c = new Fl_Choice(x, cy, w, h, label[0] ? label : nullptr);
        c->callback([](Fl_Widget* wgt, void*) {
            if (g_event_cb) {
                int cid = 0;
                for (int i = 0; i < g_ctrl_count; i++) {
                    if (g_ctrls[i].widget == wgt) { cid = g_ctrls[i].id; break; }
                }
                g_event_cb(FLTK_EVT_MENU_CMD, cid, 0);
            }
        });
        wid = c;
    } else if (cls && strstr(cls, "msctls_progress32")) {
        Fl_Progress* p = new Fl_Progress(x, cy, w, h);
        p->minimum(0);
        p->maximum(100);
        p->value(0);
        p->box(FL_DOWN_BOX);
        p->color(FL_WHITE);
        p->selection_color(0x0A246A00 | 0x24); /* ~FL_SELECTION_COLOR */
        wid = p;
    } else if (cls && strstr(cls, "msctls_statusbar32")) {
        /* Status bar: sunken box pinned to the bottom of the client area */
        Fl_Box* sb = new Fl_Box(0, 0, 0, 0);
        sb->box(FL_DOWN_BOX);
        sb->color(FL_BACKGROUND_COLOR);
        sb->labelcolor(FL_FOREGROUND_COLOR);
        sb->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_CLIP);
        if (label[0]) sb->copy_label(label);
        wid = sb;
    } else if (cls && strstr(cls, "msctls_trackbar32")) {
        Fl_Slider* sl = new Fl_Slider(x, cy, w, h, nullptr);
        sl->type(FL_HORIZONTAL);
        sl->minimum(0);
        sl->maximum(100);
        sl->value(0);
        wid = sl;
    } else if (cls && strstr(cls, "msctls_updown32")) {
        Fl_Spinner* sp = new Fl_Spinner(x, cy, w, h);
        sp->minimum(0);
        sp->maximum(100);
        sp->value(0);
        sp->textsize(11);
        wid = sp;
    } else if (cls && strstr(cls, "SysDateTimePick32")) {
        Fl_Box* dt = new Fl_Box(x, cy, w, h, label[0] ? label : "2000-01-01");
        dt->box(FL_DOWN_BOX);
        dt->color(FL_WHITE);
        dt->align(FL_ALIGN_INSIDE | FL_ALIGN_LEFT | FL_ALIGN_CLIP);
        wid = dt;
    } else {
        Fl_Box* bx = new Fl_Box(x, cy, w, h, label[0] ? label : nullptr);
        bx->box(FL_FLAT_BOX);
        bx->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_CLIP);
        wid = bx;
    }

    register_ctrl(id, wid);

    /* Status bar: pin to the bottom on window resize */
    if (cls && strstr(cls, "msctls_statusbar32")) {
        wid->resize(0, g_window->h() - MENUBAR_H - 20, g_window->w(), 20);
    }
    wid->show();
}

void fltk_update_control_text(int id, const char* text) {
    Fl_Widget* w = find_ctrl(id);
    if (!w) return;
    char label[512];
    strip_accel(label, text ? text : "", sizeof(label));
    w->copy_label(label[0] ? label : nullptr);
}

void fltk_update_control_value(int id, int value) {
    Fl_Progress* p = dynamic_cast<Fl_Progress*>(find_ctrl(id));
    if (p) p->value((double)value);
    Fl_Slider* sl = dynamic_cast<Fl_Slider*>(find_ctrl(id));
    if (sl) sl->value((double)value);
    Fl_Spinner* sp = dynamic_cast<Fl_Spinner*>(find_ctrl(id));
    if (sp) sp->value((double)value);
}


void fltk_open_color_dialog(unsigned initial) {
    static Fl_Window* cw = nullptr;
    if (cw) { delete cw; cw = nullptr; }
    cw = new Fl_Window(320, 220, "Choose Color");
    Fl_Color_Chooser* cc = new Fl_Color_Chooser(10, 10, 300, 160);
    /* initial is 0x00RRGGBB */
    cc->rgb((initial >> 16) & 0xFF, (initial >> 8) & 0xFF, initial & 0xFF);
    Fl_Button* ok = new Fl_Button(150, 180, 70, 26, "OK");
    Fl_Button* cancel = new Fl_Button(230, 180, 70, 26, "Cancel");
    ok->callback([](Fl_Widget* w, void* d) {
        Fl_Color_Chooser* ch = (Fl_Color_Chooser*)d;
        /* r()/g()/b() return 0..1 doubles; round back to 0..255 the same
           way fl_color_chooser() does for uchar outputs. */
        unsigned char r = (unsigned char)(ch->r() * 255.0 + 0.5);
        unsigned char g = (unsigned char)(ch->g() * 255.0 + 0.5);
        unsigned char b = (unsigned char)(ch->b() * 255.0 + 0.5);
        unsigned rgb = ((unsigned)r << 16) | ((unsigned)g << 8) | b;
        if (g_event_cb) g_event_cb(FLTK_EVT_COLOR_SEL, (int)rgb, 0);
        Fl_Window* ww = w->window();
        ww->hide();
    }, cc);
    cancel->callback([](Fl_Widget* w, void*) {
        w->window()->hide();
    });
    cw->end();
    cw->set_modal();
    cw->show();
    Fl::check();
}

void fltk_set_control_color(int id, unsigned color) {
    Fl_Widget* wid = find_ctrl(id);
    if (!wid) return;
    unsigned char r = (color >> 16) & 0xFF;
    unsigned char g = (color >> 8) & 0xFF;
    unsigned char b = color & 0xFF;
    wid->color(fl_rgb_color(r, g, b));
    wid->redraw();
}

void fltk_set_listbox_items(int id, const char* items) {
    Fl_Widget* wid = find_ctrl(id);
    if (!wid) return;
    Fl_Hold_Browser* lb = dynamic_cast<Fl_Hold_Browser*>(wid);
    Fl_Choice* ch = dynamic_cast<Fl_Choice*>(wid);
    Fl_Tabs* tabs = dynamic_cast<Fl_Tabs*>(wid);
    if (!lb && !ch && !tabs) return;
    if (lb) lb->clear();
    if (ch) ch->clear();
    if (tabs) tabs->clear();
    if (!items) return;
    const char* start = items;
    for (const char* p = items;; p++) {
        if (*p == '\n' || *p == '\0') {
            int len = (int)(p - start);
            if (len > 0) {
                char* tmp = (char*)malloc(len + 1);
                memcpy(tmp, start, len);
                tmp[len] = 0;
                if (lb) lb->add(tmp);
                if (ch) ch->add(tmp);
                if (tabs) {
                    Fl_Group* g = new Fl_Group(0, 0, tabs->w(), tabs->h() - 20, tmp);
                    tabs->add(g);
                    g->end();
                }
                free(tmp);
            }
            if (*p == '\0') break;
            start = p + 1;
        }
    }
    if (lb) lb->redraw();
    if (ch) ch->redraw();
    if (tabs) tabs->redraw();
}

void fltk_set_control_checked(int id, int checked) {
    Fl_Widget* wid = find_ctrl(id);
    if (!wid) return;
    if (Fl_Check_Button* cb = dynamic_cast<Fl_Check_Button*>(wid)) {
        cb->value(checked ? 1 : 0);
        cb->redraw();
    } else if (Fl_Round_Button* rb = dynamic_cast<Fl_Round_Button*>(wid)) {
        rb->value(checked ? 1 : 0);
        rb->redraw();
    }
}

void fltk_update_control_range(int id, int min, int max) {
    Fl_Progress* p = dynamic_cast<Fl_Progress*>(find_ctrl(id));
    if (p) {
        p->minimum((double)min);
        p->maximum((double)max);
    }
}

/* ───────────────────────────────────── context menu */

/* Minimal JSON scan for {"id":N,"text":"..."} and "separator":true */
void fltk_show_context_menu(int x, int y, const char* json, int len) {
    if (!g_window) return;

    Fl_Menu_Button* menu = new Fl_Menu_Button(x, y + MENUBAR_H, 1, 1);
    menu->type(Fl_Menu_Button::POPUP3);

    int idx = 0;
    while (idx < len) {
        /* find next "id":N */
        const char* id_pos = strstr(json + idx, "\"id\":");
        if (!id_pos || id_pos - json >= len) break;
        int id = atoi(id_pos + 5);

        const char* sep_pos = strstr(id_pos, "\"separator\":true");
        if (sep_pos && sep_pos < strstr(id_pos, "\"id\":") + 0) {
            /* keep scanning below */
        }

        /* find "text":"..." */
        const char* tpos = strstr(id_pos, "\"text\":\"");
        char text[256] = "";
        if (tpos && tpos - json < len) {
            const char* tstart = tpos + 8;
            const char* tend = tstart;
            while (*tend && *tend != '"' && tend - json < len) tend++;
            size_t n = (size_t)(tend - tstart);
            if (n >= sizeof(text)) n = sizeof(text) - 1;
            memcpy(text, tstart, n);
            text[n] = 0;
            /* unescape \\\" and \\n minimally */
            char out[256]; size_t o = 0;
            for (size_t i = 0; i < n && o + 1 < sizeof(out); i++) {
                if (text[i] == '\\' && i + 1 < n) {
                    if (text[i+1] == 'n') { out[o++] = '\n'; i++; }
                    else if (text[i+1] == '"') { out[o++] = '"'; i++; }
                    else if (text[i+1] == '\\') { out[o++] = '\\'; i++; }
                    else out[o++] = text[i];
                } else out[o++] = text[i];
            }
            out[o] = 0;
            memcpy(text, out, o + 1);
        }

        bool separator = false;
        const char* sp = strstr(id_pos, "\"separator\":true");
        if (sp && sp - json < len && sp < tpos) separator = true;

        if (separator) {
            menu->add("|", 0, nullptr);
        } else {
            menu->add(text[0] ? text : "Item", 0,
                      [](Fl_Widget*, void* data) {
                          if (g_event_cb) g_event_cb(FLTK_EVT_MENU_CMD, (int)(intptr_t)data, 0);
                      },
                      (void*)(intptr_t)id);
        }

        /* advance past this item's closing "}" */
        const char* close = strchr(id_pos, '}');
        idx = close ? (int)(close - json) + 1 : len;
    }

    menu->popup();
    delete menu;
}

/* ─────────────────────────────────── modal dialogs */

#include <FL/Fl_Input.H>

/* Dialog-unit -> pixel scale (matches the web frontend) */
static const float DLG_SCALE_X = 1.75f;
static const float DLG_SCALE_Y = 1.875f;

static Fl_Window* g_dialog = nullptr;

static void dialog_button_cb(Fl_Widget* wgt, void* data) {
    long id = (long)data;
    if (g_event_cb) g_event_cb(FLTK_EVT_MENU_CMD, (int)id, 0);
    /* Close the dialog window after a button click */
    if (g_dialog) {
        g_dialog->hide();
        delete g_dialog;
        g_dialog = nullptr;
    }
    (void)wgt;
}

void fltk_show_dialog(const char* title, int cx, int cy) {
    if (g_dialog) { delete g_dialog; g_dialog = nullptr; }
    g_dialog = new Fl_Window((int)(cx * DLG_SCALE_X), (int)(cy * DLG_SCALE_Y), title);
    g_dialog->begin();
}

void fltk_add_dialog_item(const char* cls, int id, int x, int y, int cx, int cy,
                          const char* text) {
    if (!g_dialog) return;
    int px = (int)(x * DLG_SCALE_X);
    int py = (int)(y * DLG_SCALE_Y);
    int pw = (int)(cx * DLG_SCALE_X);
    int ph = (int)(cy * DLG_SCALE_Y);
    if (pw < 1) pw = 1;
    if (ph < 1) ph = 1;

    char label[512];
    strip_accel(label, text ? text : "", sizeof(label));

    if (cls && strstr(cls, "Button")) {
        Fl_Button* b = new Fl_Button(px, py, pw, ph, label[0] ? label : nullptr);
        b->callback(dialog_button_cb, (void*)(intptr_t)id);
    } else if (cls && strstr(cls, "Edit")) {
        Fl_Input* in = new Fl_Input(px, py, pw, ph);
        if (label[0]) in->value(label);
    } else if (cls && strstr(cls, "ComboBox")) {
        Fl_Input* in = new Fl_Input(px, py, pw, ph);
        if (label[0]) in->value(label);
    } else if (cls && strstr(cls, "ListBox")) {
        (void)new Fl_Hold_Browser(px, py, pw, ph);
    } else {
        Fl_Box* bx = new Fl_Box(px, py, pw, ph, label[0] ? label : nullptr);
        bx->box(FL_FLAT_BOX);
        bx->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_CLIP);
    }
}

void fltk_finish_dialog(void) {
    if (!g_dialog) return;
    g_dialog->end();
    g_dialog->set_modal();
    g_dialog->show();
    g_dialog->redraw();
}

void fltk_close_dialog(void) {
    if (g_dialog) {
        g_dialog->hide();
        delete g_dialog;
        g_dialog = nullptr;
    }
}

/* ─────────────────────────────── clipboard + icon */

void fltk_set_clipboard(const char* text) {
    if (text) Fl::copy(text, (int)strlen(text), 1);
}

void fltk_set_icon(const unsigned char* png, int len) {
    if (!g_window || !png || len <= 0) return;
    Fl_PNG_Image* img = new Fl_PNG_Image("zine-icon", png, len);
    if (img && img->w() > 0) {
        g_window->icon(img);
        g_window->redraw();
    }
}

/* ─────────────────────────────── file dialog */

#include <FL/Fl_Native_File_Chooser.H>

static fltk_file_cb g_file_cb = nullptr;

void fltk_set_file_callback(fltk_file_cb cb) {
    g_file_cb = cb;
}

/* Minimal filter parsing: "Text\0*.txt\0All\0*.*\0\0" -> "Text (*.txt)" */
static void parse_filters(const char* raw, char* out, size_t cap) {
    out[0] = 0;
    if (!raw || !raw[0]) return;
    size_t o = 0;
    size_t i = 0;
    int first = 1;
    while (raw[i] && o + 1 < cap) {
        if (raw[i] == 0) {
            /* end of a (name, pattern) pair; skip pattern, append name */
            i += 1;
            while (raw[i] && o + 1 < cap) i += 1; /* skip pattern */
            if (first) first = 0; else if (o + 1 < cap) out[o++] = '\t';
            continue;
        }
        out[o++] = raw[i];
        i += 1;
    }
    out[o] = 0;
}

void fltk_open_file_dialog(const char* filters, int is_save) {
    Fl_Native_File_Chooser nc(is_save ? Fl_Native_File_Chooser::BROWSE_SAVE_FILE
                                      : Fl_Native_File_Chooser::BROWSE_FILE);
    nc.title(is_save ? "Save As" : "Open");
    char filter_buf[512];
    parse_filters(filters, filter_buf, sizeof(filter_buf));
    if (filter_buf[0]) nc.filter(filter_buf);

    int rc = nc.show();
    if (g_file_cb) {
        if (rc == 0 && nc.filename() && nc.filename()[0]) {
            g_file_cb(nc.filename(), 0);
        } else {
            g_file_cb("", 1);
        }
    }
}

/* ─────────────────────────────── font dialog */

#include <FL/Fl_Choice.H>
#include <FL/Fl_Input.H>
#include <FL/Fl_Check_Button.H>
#include <FL/Fl_Button.H>
#include <vector>
#include <string>

static fltk_font_cb g_font_cb = nullptr;

void fltk_set_font_callback(fltk_font_cb cb) {
    g_font_cb = cb;
}

static Fl_Choice*       g_font_choice = nullptr;
static Fl_Input*        g_font_size   = nullptr;
static Fl_Check_Button* g_font_bold   = nullptr;
static Fl_Check_Button* g_font_italic = nullptr;
static Fl_Box*          g_font_preview = nullptr;
static std::vector<std::string>* g_font_names = nullptr;

static void update_font_preview() {
    if (!g_font_preview) return;
    int idx = g_font_choice ? g_font_choice->value() : 0;
    g_font_preview->labelfont((Fl_Font)(idx >= 0 ? idx : 0));
    int sz = g_font_size ? atoi(g_font_size->value()) : 10;
    if (sz < 1) sz = 10;
    if (sz > 72) sz = 72;
    g_font_preview->labelsize(sz);
    g_font_preview->redraw();
}

static void font_change_cb(Fl_Widget*, void*) {
    update_font_preview();
}

static void font_ok_cb(Fl_Widget* w, void*) {
    int idx = g_font_choice ? g_font_choice->value() : -1;
    const char* nm = (idx >= 0 && g_font_names) ? (*g_font_names)[idx].c_str() : "MS Sans Serif";
    int sz = g_font_size ? atoi(g_font_size->value()) : 10;
    if (sz < 1) sz = 10;
    if (sz > 72) sz = 72;
    if (g_font_cb) g_font_cb(nm, sz,
                             (g_font_bold && g_font_bold->value()) ? 1 : 0,
                             (g_font_italic && g_font_italic->value()) ? 1 : 0, 0);
    if (w->window()) w->window()->hide();
}

static void font_cancel_cb(Fl_Widget* w, void*) {
    if (g_font_cb) g_font_cb("", 0, 0, 0, 1);
    if (w->window()) w->window()->hide();
}

void fltk_open_font_dialog(const char* face, int size, int bold, int italic) {
    static Fl_Window* fw = nullptr;
    if (fw) { delete fw; fw = nullptr; }
    if (!g_font_names) g_font_names = new std::vector<std::string>();
    g_font_names->clear();

    int nfonts = Fl::set_fonts();
    for (int i = 0; i < nfonts; i++) {
        const char* nm = Fl::get_font_name((Fl_Font)i);
        if (nm && nm[0]) g_font_names->push_back(nm);
    }

    fw = new Fl_Window(430, 300, "Choose Font");
    g_font_choice = new Fl_Choice(50, 25, 250, 25);
    g_font_choice->tooltip("Font");
    for (size_t i = 0; i < g_font_names->size(); i++) {
        g_font_choice->add((*g_font_names)[i].c_str());
    }
    int preselect = 0;
    if (face && face[0]) {
        for (size_t i = 0; i < g_font_names->size(); i++) {
            if (strcmp((*g_font_names)[i].c_str(), face) == 0) { preselect = (int)i; break; }
        }
    }
    g_font_choice->value(preselect);

    g_font_size = new Fl_Input(330, 25, 60, 25);
    char sizebuf[16];
    snprintf(sizebuf, sizeof(sizebuf), "%d", size >= 1 ? size : 10);
    g_font_size->value(sizebuf);

    g_font_bold = new Fl_Check_Button(50, 65, 120, 25, "Bold");
    g_font_bold->value(bold ? 1 : 0);
    g_font_italic = new Fl_Check_Button(180, 65, 120, 25, "Italic");
    g_font_italic->value(italic ? 1 : 0);

    g_font_preview = new Fl_Box(FL_FRAME_BOX, 50, 100, 340, 90, "AaBbYyZz 0123456789");
    g_font_preview->align(FL_ALIGN_INSIDE | FL_ALIGN_CENTER);

    Fl_Button* ok = new Fl_Button(240, 260, 70, 26, "OK");
    Fl_Button* cancel = new Fl_Button(320, 260, 70, 26, "Cancel");
    ok->callback(font_ok_cb);
    cancel->callback(font_cancel_cb);
    g_font_choice->callback(font_change_cb);
    g_font_size->callback(font_change_cb);
    g_font_bold->callback(font_change_cb);
    g_font_italic->callback(font_change_cb);

    update_font_preview();

    fw->end();
    fw->set_modal();
    fw->show();
    Fl::check();
}

/* ─────────────────────────────── edit / rich-edit control */

#include <FL/Fl_Input.H>
#include <FL/Fl_Multiline_Input.H>

static Fl_Input* g_edit_input = nullptr;
static fltk_edit_text_cb g_edit_text_cb = nullptr;
static bool g_edit_guest_change = false;

void fltk_set_edit_text_callback(fltk_edit_text_cb cb) {
    g_edit_text_cb = cb;
}

/* User-typing callback: syncs the widget text back to the guest buffer
 * (mirrors the web textarea's edit_text message). Guest-driven updates set
 * g_edit_guest_change so they don't echo back. */
static void edit_input_cb(Fl_Widget* w, void*) {
    if (g_edit_guest_change) return;
    Fl_Input* inp = (Fl_Input*)w;
    if (g_edit_text_cb && inp) g_edit_text_cb(inp->value());
}

void fltk_edit_show(int multiline) {
    if (g_edit_input) { delete g_edit_input; g_edit_input = nullptr; }
    if (multiline) {
        g_edit_input = new Fl_Multiline_Input(10, 10, 100, 40);
    } else {
        g_edit_input = new Fl_Input(10, 10, 100, 25);
    }
    g_edit_input->textfont(FL_COURIER);
    g_edit_input->callback(edit_input_cb);
    g_edit_input->when(FL_WHEN_CHANGED);
    g_edit_input->show();
    if (g_window) g_window->redraw();
}

void fltk_edit_resize(int x, int y, int w, int h) {
    if (g_edit_input) { g_edit_input->resize(x, y, w, h); g_edit_input->redraw(); }
}

void fltk_edit_set_text(const char* text) {
    if (!g_edit_input) return;
    g_edit_guest_change = true;
    g_edit_input->value(text ? text : "");
    g_edit_guest_change = false;
}

/* Normalized selection [b, e): Fl_Input selection is between position() and
 * mark(); return b <= e ordered. */
static void edit_norm_sel(int* b, int* e) {
    int pos = g_edit_input->position();
    int mk = g_edit_input->mark();
    *b = pos < mk ? pos : mk;
    *e = pos < mk ? mk : pos;
}

void fltk_edit_set_sel(int start, int end) {
    if (!g_edit_input) return;
    int len = (int)strlen(g_edit_input->value());
    if (start < 0) start = 0;
    if (end < 0 || end > len) end = len;
    if (start > len) start = len;
    g_edit_guest_change = true;
    g_edit_input->position(end);
    g_edit_input->mark(start);
    g_edit_guest_change = false;
}

void fltk_edit_replace_sel(const char* text) {
    if (!g_edit_input) return;
    int b, e;
    edit_norm_sel(&b, &e);
    const char* cur = g_edit_input->value();
    int len = (int)strlen(cur);
    int n = text ? (int)strlen(text) : 0;
    char* tmp = (char*)malloc((size_t)len - (e - b) + n + 1);
    if (!tmp) return;
    memcpy(tmp, cur, (size_t)b);
    if (text && n > 0) memcpy(tmp + b, text, (size_t)n);
    memcpy(tmp + b + n, cur + e, (size_t)(len - e));
    tmp[(size_t)len - (e - b) + n] = 0;
    g_edit_guest_change = true;
    g_edit_input->value(tmp);
    g_edit_input->position(b + n);
    g_edit_input->mark(b + n);
    g_edit_guest_change = false;
    free(tmp);
}

void fltk_edit_insert_char(unsigned ch) {
    if (!g_edit_input) return;
    char utf8[4];
    int n = 0;
    if (ch < 0x80) {
        utf8[0] = (char)ch; n = 1;
    } else if (ch < 0x800) {
        utf8[0] = (char)(0xC0 | (ch >> 6));
        utf8[1] = (char)(0x80 | (ch & 0x3F)); n = 2;
    } else {
        utf8[0] = (char)(0xE0 | (ch >> 12));
        utf8[1] = (char)(0x80 | ((ch >> 6) & 0x3F));
        utf8[2] = (char)(0x80 | (ch & 0x3F)); n = 3;
    }
    if (ch == 0x08) { /* backspace: delete the char before the cursor */
        int b, e;
        edit_norm_sel(&b, &e);
        if (b == e && b > 0) b -= 1;
        g_edit_guest_change = true;
        g_edit_input->replace(b, e, "");
        g_edit_input->position(b);
        g_edit_input->mark(b);
        g_edit_guest_change = false;
        return;
    }
    if (ch < 0x20 && ch != '\t') return;
    g_edit_guest_change = true;
    g_edit_input->insert(utf8, n);
    g_edit_guest_change = false;
}

void fltk_edit_undo(void) {
    /* Fl_Input has no undo; no-op */
}

void fltk_edit_scroll_caret(void) {
    if (g_edit_input) g_edit_input->position(g_edit_input->position());
}

/* ─────────────────────────────── print dialog */

static fltk_print_cb g_print_cb = nullptr;

void fltk_set_print_callback(fltk_print_cb cb) {
    g_print_cb = cb;
}

static Fl_Input* g_print_from = nullptr;
static Fl_Input* g_print_to = nullptr;
static Fl_Input* g_print_copies = nullptr;

static void print_ok_cb(Fl_Widget* w, void*) {
    int from = atoi(g_print_from ? g_print_from->value() : "1");
    int to = atoi(g_print_to ? g_print_to->value() : "1");
    int copies = atoi(g_print_copies ? g_print_copies->value() : "1");
    if (from < 1) from = 1;
    if (to < from) to = from;
    if (copies < 1) copies = 1;
    if (g_print_cb) g_print_cb(from, to, copies, 0);
    if (w->window()) w->window()->hide();
}

static void print_cancel_cb(Fl_Widget* w, void*) {
    if (g_print_cb) g_print_cb(0, 0, 0, 1);
    if (w->window()) w->window()->hide();
}

void fltk_open_print_dialog(int from_page, int to_page, int min_page, int max_page, int copies) {
    static Fl_Window* pw = nullptr;
    if (pw) { delete pw; pw = nullptr; }
    if (copies < 1) copies = 1;
    if (from_page < min_page) from_page = min_page;
    if (to_page < from_page) to_page = from_page;
    if (to_page > max_page) to_page = max_page;

    pw = new Fl_Window(300, 150, "Print");
    Fl_Box* range_label = new Fl_Box(FL_NO_BOX, 10, 12, 60, 25, "Pages:");
    range_label->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_print_from = new Fl_Input(80, 12, 40, 25);
    g_print_to = new Fl_Input(140, 12, 40, 25);
    Fl_Box* dash = new Fl_Box(FL_NO_BOX, 122, 12, 16, 25, "-");
    dash->align(FL_ALIGN_INSIDE | FL_ALIGN_CENTER);
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", from_page);
    g_print_from->value(buf);
    snprintf(buf, sizeof(buf), "%d", to_page);
    g_print_to->value(buf);

    Fl_Box* copies_label = new Fl_Box(FL_NO_BOX, 10, 50, 60, 25, "Copies:");
    copies_label->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_print_copies = new Fl_Input(80, 50, 40, 25);
    snprintf(buf, sizeof(buf), "%d", copies);
    g_print_copies->value(buf);

    Fl_Button* ok = new Fl_Button(110, 105, 80, 26, "Print");
    Fl_Button* cancel = new Fl_Button(200, 105, 80, 26, "Cancel");
    ok->callback(print_ok_cb);
    cancel->callback(print_cancel_cb);

    pw->end();
    pw->set_modal();
    pw->show();
    Fl::check();
}

/* ─────────────────────────────── find / replace dialog (modeless) */

#include <FL/Fl_Round_Button.H>

static fltk_find_cb g_find_cb = nullptr;

void fltk_set_find_callback(fltk_find_cb cb) {
    g_find_cb = cb;
}

static Fl_Input* g_find_input = nullptr;
static Fl_Input* g_repl_input = nullptr;
static Fl_Check_Button* g_find_match = nullptr;
static Fl_Round_Button* g_find_down = nullptr;
static Fl_Round_Button* g_find_up = nullptr;

static void find_emit(const char* action) {
    if (g_find_cb) {
        const char* find_text = g_find_input ? g_find_input->value() : "";
        const char* repl_text = g_repl_input ? g_repl_input->value() : "";
        g_find_cb(action, find_text, repl_text,
                  (g_find_match && g_find_match->value()) ? 1 : 0,
                  (g_find_up && g_find_up->value()) ? 0 : 1);
    }
}

static void find_next_cb(Fl_Widget*, void*) { find_emit("find_next"); }
static void find_replace_cb(Fl_Widget*, void*) { find_emit("replace"); }
static void find_replace_all_cb(Fl_Widget*, void*) { find_emit("replace_all"); }
static void find_close_cb(Fl_Widget*, void*) { find_emit("close"); }

void fltk_open_find_dialog(const char* find_text, const char* replace_text, int is_replace) {
    static Fl_Window* fw = nullptr;
    if (fw) { delete fw; fw = nullptr; }
    const int W = 360;
    const int H = is_replace ? 190 : 130;
    fw = new Fl_Window(W, H, is_replace ? "Replace" : "Find");

    Fl_Box* fl = new Fl_Box(FL_NO_BOX, 10, 14, 60, 25, "Find:");
    fl->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_find_input = new Fl_Input(80, 14, 250, 25);
    g_find_input->value(find_text ? find_text : "");

    int y = 48;
    if (is_replace) {
        Fl_Box* rl = new Fl_Box(FL_NO_BOX, 10, y, 60, 25, "Replace:");
        rl->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
        g_repl_input = new Fl_Input(80, y, 250, 25);
        g_repl_input->value(replace_text ? replace_text : "");
        y += 34;
    } else {
        g_repl_input = nullptr;
    }

    g_find_match = new Fl_Check_Button(80, y, 120, 22, "Match case");
    g_find_down = new Fl_Round_Button(210, y, 60, 22, "Down");
    g_find_up = new Fl_Round_Button(270, y, 60, 22, "Up");
    g_find_down->value(1);
    g_find_down->type(FL_RADIO_BUTTON);
    g_find_up->type(FL_RADIO_BUTTON);

    int by = H - 40;
    if (is_replace) {
        Fl_Button* rb = new Fl_Button(10, by, 90, 26, "Replace");
        Fl_Button* ra = new Fl_Button(105, by, 100, 26, "Replace All");
        Fl_Button* fn = new Fl_Button(210, by, 80, 26, "Find Next");
        Fl_Button* cl = new Fl_Button(295, by, 55, 26, "Close");
        rb->callback(find_replace_cb);
        ra->callback(find_replace_all_cb);
        fn->callback(find_next_cb);
        cl->callback(find_close_cb);
    } else {
        Fl_Button* fn = new Fl_Button(210, by, 80, 26, "Find Next");
        Fl_Button* cl = new Fl_Button(295, by, 55, 26, "Close");
        fn->callback(find_next_cb);
        cl->callback(find_close_cb);
    }

    fw->end();
    fw->set_modal();
    fw->show();
    Fl::check();
}

/* ─────────────────────────────── page setup dialog */

static fltk_pagesetup_cb g_pagesetup_cb = nullptr;

void fltk_set_pagesetup_callback(fltk_pagesetup_cb cb) {
    g_pagesetup_cb = cb;
}

static Fl_Input* g_ps_left = nullptr;
static Fl_Input* g_ps_top = nullptr;
static Fl_Input* g_ps_right = nullptr;
static Fl_Input* g_ps_bottom = nullptr;
static Fl_Check_Button* g_ps_landscape = nullptr;

static int ps_get_int(Fl_Input* in, int dflt) {
    if (!in) return dflt;
    int v = atoi(in->value());
    return v >= 0 ? v : dflt;
}

static void ps_ok_cb(Fl_Widget* w, void*) {
    if (g_pagesetup_cb) {
        g_pagesetup_cb(ps_get_int(g_ps_left, 1000), ps_get_int(g_ps_top, 1000),
                       ps_get_int(g_ps_right, 1000), ps_get_int(g_ps_bottom, 1000),
                       8500, 11000,
                       (g_ps_landscape && g_ps_landscape->value()) ? 1 : 0, 0);
    }
    if (w->window()) w->window()->hide();
}

static void ps_cancel_cb(Fl_Widget* w, void*) {
    if (g_pagesetup_cb) g_pagesetup_cb(0, 0, 0, 0, 0, 0, 0, 1);
    if (w->window()) w->window()->hide();
}

void fltk_open_page_setup_dialog(int left, int top, int right, int bottom, int paper_w, int paper_h, int orientation) {
    (void)paper_w; (void)paper_h;
    static Fl_Window* pw = nullptr;
    if (pw) { delete pw; pw = nullptr; }
    pw = new Fl_Window(320, 210, "Page Setup");

    Fl_Box* mh = new Fl_Box(FL_NO_BOX, 10, 10, 300, 18, "Margins:");
    mh->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE);

    Fl_Box* ll = new Fl_Box(FL_NO_BOX, 10, 34, 60, 25, "Left:");
    ll->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_ps_left = new Fl_Input(78, 34, 60, 25);
    Fl_Box* tl = new Fl_Box(FL_NO_BOX, 150, 34, 60, 25, "Top:");
    tl->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_ps_top = new Fl_Input(218, 34, 60, 25);

    Fl_Box* rl = new Fl_Box(FL_NO_BOX, 10, 66, 60, 25, "Right:");
    rl->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_ps_right = new Fl_Input(78, 66, 60, 25);
    Fl_Box* bl = new Fl_Box(FL_NO_BOX, 150, 66, 60, 25, "Bottom:");
    bl->align(FL_ALIGN_RIGHT | FL_ALIGN_INSIDE);
    g_ps_bottom = new Fl_Input(218, 66, 60, 25);

    char buf[16];
    snprintf(buf, sizeof(buf), "%d", left); g_ps_left->value(buf);
    snprintf(buf, sizeof(buf), "%d", top); g_ps_top->value(buf);
    snprintf(buf, sizeof(buf), "%d", right); g_ps_right->value(buf);
    snprintf(buf, sizeof(buf), "%d", bottom); g_ps_bottom->value(buf);

    g_ps_landscape = new Fl_Check_Button(10, 100, 120, 22, "Landscape");
    g_ps_landscape->value(orientation ? 1 : 0);

    Fl_Button* ok = new Fl_Button(110, 165, 80, 26, "OK");
    Fl_Button* cancel = new Fl_Button(200, 165, 80, 26, "Cancel");
    ok->callback(ps_ok_cb);
    cancel->callback(ps_cancel_cb);

    pw->end();
    pw->set_modal();
    pw->show();
    Fl::check();
}
