const std = @import("std");
const renderer = @import("renderer.zig");

// =============================================================================
// FLTK Backend Stub
//
// This module mirrors the web_ui.zig interface but targets native FLTK widgets.
// Phase 1: all functions are no-ops. Phase 3 will wire them to actual FLTK calls.
// =============================================================================

var g_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    std.debug.print("\n>>> FLTK backend initialized (stub — no GUI yet) <<<\n\n", .{});
}

// --- Framebuffer ---

pub fn pushFrame() void {
    // TODO: Blit global_framebuf into Fl_RGB_Image and redraw canvas widget
}

// --- Window Chrome ---

pub fn setTitle(_: []const u8) void {
    // TODO: Fl_Window::label(title)
}

pub fn setWindowPos(_: i32, _: i32, _: i32, _: i32) void {
    // TODO: Fl_Window::resize(x, y, w, h)
}

pub fn setResolution(_: u32, _: u32) void {
    // TODO: Resize Fl_RGB_Image / pixel buffer
}

pub fn setIcon(_: []const u8) void {
    // TODO: Fl_Window::icon() with Fl_RGB_Image
}

// --- Menu ---

pub fn setMenu(_: []const u8) void {
    // TODO: Parse menu JSON, build Fl_Menu_Bar items via add()
}

pub fn enableMenuItem(_: u32, _: bool) void {
    // TODO: Fl_Menu_Bar::mode(idx, FL_MENU_INACTIVE)
}

pub fn checkMenuItem(_: u32, _: bool) void {
    // TODO: Fl_Menu_Bar::mode(idx, FL_MENU_TOGGLE | FL_MENU_VALUE)
}

// --- Edit Control ---

pub fn showEditControl(_: bool) void {
    // TODO: Create Fl_Text_Editor + Fl_Text_Buffer
}

pub fn resizeEditControl(_: i32, _: i32, _: i32, _: i32) void {
    // TODO: editor->resize(x, y, w, h)
}

pub fn setEditFont(_: usize, _: []const u8, _: i32, _: bool, _: bool) void {
    // TODO: editor->textfont() + textsize()
}

pub fn setEditSelection(_: i32, _: i32) void {
    // TODO: editor->buffer()->select(start, end)
}

pub fn replaceEditSelection(_: []const u8) void {
    // TODO: buffer->replace_selection(text)
}

pub fn editUndo() void {
    // TODO: Fl_Text_Buffer::undo()
}

pub fn editScrollCaret() void {
    // TODO: editor->show_insert_position()
}

pub fn setEditText(_: []const u8) void {
    // TODO: buffer->text(text)
}

// --- Status Bar ---

pub fn setStatusBarParts(_: usize) void {
    // TODO: Create Fl_Group with N Fl_Box children
}

pub fn setStatusBarText(_: usize, _: []const u8) void {
    // TODO: status_boxes[part]->label(text)
}

// --- Clipboard ---

pub fn setClipboard(_: []const u8) void {
    // TODO: Fl::copy(text, len, 1)
}

// --- Context Menu ---

pub fn showContextMenu(_: i32, _: i32, _: []const u8) void {
    // TODO: Fl_Menu_Button popup at (x, y)
}

// --- Dialogs ---

pub fn showMessageBox(_: []const u8, _: []const u8) void {
    // TODO: fl_message_title(title); fl_alert(text)
}

pub fn showDialog(_: []const u8) void {
    // TODO: Create Fl_Window with controls parsed from JSON
}

pub fn showControls(_: []const u8) void {
    // TODO: Parse JSON, create FLTK child widgets
}

pub fn addControl(_: []const u8, _: usize, _: i32, _: i32, _: i32, _: i32, _: u32, _: []const u8) void {
    // TODO: Map class name → FLTK widget and create
}

pub fn updateControlText(_: i32, _: []const u8) void {
    // TODO: Find widget by ID, set label(text) or value(text)
}

pub fn openFileDialog(_: ?[]const u8, _: bool) void {
    // TODO: Fl_Native_File_Chooser
}

pub fn openFontDialog(_: []const u8, _: i32, _: bool, _: bool) void {
    // TODO: Custom Fl_Window with font selection
}

pub fn closeDialog() void {
    // TODO: dialog_window->hide()
}

// --- Audio ---

pub fn setVolume(_: f32) void {
    // TODO: Audio backend volume control
}

pub fn setAudioFormat(_: u32, _: u16, _: u16) void {
    // TODO: Configure audio backend
}

pub fn pushAudio(_: []const u8) void {
    // TODO: Write PCM to audio stream
}
