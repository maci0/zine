# UI TODOs

This document tracks unimplemented UI features for the FLTK bridge, extracted from `src/gui/fltk_ui.zig`.

## Window & Icon Management
- [ ] `Fl_Window::icon()` with `Fl_RGB_Image` (L225)
- [ ] Custom `Fl_Window` with font selection (L336)
- [ ] `dialog_window->hide()` (L340)

## Text Editor & Buffer
- [ ] Create `Fl_Text_Editor` + `Fl_Text_Buffer` (L253)
- [ ] `editor->resize(x, y, w, h)` (L257)
- [ ] `editor->textfont()` + `textsize()` (L261)
- [ ] `editor->buffer()->select(start, end)` (L265)
- [ ] `buffer->replace_selection(text)` (L269)
- [ ] `Fl_Text_Buffer::undo()` (L273)
- [ ] `editor->show_insert_position()` (L277)
- [ ] `buffer->text(text)` (L281)

## Status Bar & Groups
- [ ] Create `Fl_Group` with N `Fl_Box` children (L287)
- [ ] `status_boxes[part]->label(text)` (L291)

## Clipboard & Menus
- [ ] `Fl::copy(text, len, 1)` (L297)
- [ ] `Fl_Menu_Button` popup at (x, y) (L303)

## Dialogs & JSON Parsing
- [ ] Create `Fl_Window` with controls parsed from JSON (L316)
- [ ] Parse JSON, create FLTK child widgets (L320)
- [ ] Map class name → FLTK widget and create (L324)
- [ ] Find widget by ID, set `label(text)` or `value(text)` (L328)
- [ ] `Fl_Native_File_Chooser` (L332)

## Audio Controls
- [ ] Audio backend volume control (L346)
- [ ] Configure audio backend (L350)
- [ ] Write PCM to audio stream (L354)
