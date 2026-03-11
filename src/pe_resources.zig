const std = @import("std");

pub const IMAGE_RESOURCE_DIRECTORY = extern struct {
    Characteristics: u32,
    TimeDateStamp: u32,
    MajorVersion: u16,
    MinorVersion: u16,
    NumberOfNamedEntries: u16,
    NumberOfIdEntries: u16,
};

pub const IMAGE_RESOURCE_DIRECTORY_ENTRY = extern struct {
    NameOrId: u32,
    OffsetToData: u32,
};

pub const IMAGE_RESOURCE_DATA_ENTRY = extern struct {
    OffsetToData: u32,
    Size: u32,
    CodePage: u32,
    Reserved: u32,
};

pub const RT_CURSOR = 1;
pub const RT_BITMAP = 2;
pub const RT_ICON = 3;
pub const RT_MENU = 4;
pub const RT_DIALOG = 5;
pub const RT_STRING = 6;
pub const RT_FONTDIR = 7;
pub const RT_FONT = 8;
pub const RT_ACCELERATOR = 9;
pub const RT_RCDATA = 10;
pub const RT_MESSAGETABLE = 11;
pub const RT_GROUP_CURSOR = 12;
pub const RT_GROUP_ICON = 14;
pub const RT_VERSION = 16;
pub const RT_DLGINCLUDE = 17;
pub const RT_PLUGPLAY = 19;
pub const RT_VXD = 20;
pub const RT_ANICURSOR = 21;
pub const RT_ANIICON = 22;
pub const RT_HTML = 23;
pub const RT_MANIFEST = 24;

// Menu structures (simplified)
pub const MENUITEMTEMPLATEHEADER = extern struct {
    versionNumber: u16, // Usually 0
    offset: u16,        // Usually 0
};

// Dialog structures
pub const DLGTEMPLATE = extern struct {
    style: u32,
    dwExtendedStyle: u32,
    cdit: u16, // Number of items
    x: i16,
    y: i16,
    cx: i16,
    cy: i16,
    // Variable length stuff follows: menu, class, title (null terminated utf-16 strings)
};