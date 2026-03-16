# UI TODOs

This document tracks unimplemented UI features for the FLTK bridge, extracted from `src/gui/fltk_ui.zig`.

## Window & Icon Management
- [ ] `Fl_Window::icon()` with `Fl_RGB_Image` (L222)
- [ ] Custom `Fl_Window` with font selection (L329)
- [ ] `dialog_window->hide()` (L333)

## Text Editor & Buffer
- [ ] Create `Fl_Text_Editor` + `Fl_Text_Buffer` (L247)
- [ ] `editor->resize(x, y, w, h)` (L251)
- [ ] `editor->textfont()` + `textsize()` (L255)
- [ ] `editor->buffer()->select(start, end)` (L259)
- [ ] `buffer->replace_selection(text)` (L263)
- [ ] `Fl_Text_Buffer::undo()` (L267)
- [ ] `editor->show_insert_position()` (L271)
- [ ] `buffer->text(text)` (L275)

## Status Bar & Groups
- [ ] Create `Fl_Group` with N `Fl_Box` children (L281)
- [ ] `status_boxes[part]->label(text)` (L285)

## Clipboard & Menus
- [ ] `Fl::copy(text, len, 1)` (L291)
- [ ] `Fl_Menu_Button` popup at (x, y) (L297)

## Dialogs & JSON Parsing
- [ ] Create `Fl_Window` with controls parsed from JSON (L309)
- [ ] Parse JSON, create FLTK child widgets (L313)
- [ ] Map class name → FLTK widget and create (L317)
- [ ] Find widget by ID, set `label(text)` or `value(text)` (L321)
- [ ] `Fl_Native_File_Chooser` (L325)

## Audio Controls
- [ ] Audio backend volume control (L339)
- [ ] Configure audio backend (L343)
- [ ] Write PCM to audio stream (L347)
