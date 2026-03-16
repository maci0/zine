//! Portable Executable (PE) resource structures and constants.
//!
//! This module defines the structures used for the resource directory in PE files,
//! including resource directories, directory entries, and data entries. It also
//! defines the standard resource types (RT_*).

const std = @import("std");

/// Resource directory header.
pub const IMAGE_RESOURCE_DIRECTORY = extern struct {
    /// Resource flags (reserved).
    Characteristics: u32,
    /// The time and date that the resource data was created.
    TimeDateStamp: u32,
    /// The major version number.
    MajorVersion: u16,
    /// The minor version number.
    MinorVersion: u16,
    /// The number of directory entries immediately following the table that use strings to identify Type, Name, or Language.
    NumberOfNamedEntries: u16,
    /// The number of directory entries immediately following the Name entries that use numeric identifiers for Type, Name, or Language.
    NumberOfIdEntries: u16,
};

/// Entry in a resource directory.
pub const IMAGE_RESOURCE_DIRECTORY_ENTRY = extern struct {
    /// The name or identifier of the resource.
    NameOrId: u32,
    /// The offset to the data or next directory level.
    OffsetToData: u32,
};

/// Leaf node in the resource tree, pointing to the actual data.
pub const IMAGE_RESOURCE_DATA_ENTRY = extern struct {
    /// The RVA of the resource data.
    OffsetToData: u32,
    /// The size of the resource data, in bytes.
    Size: u32,
    /// The code page used to decode the resource data.
    CodePage: u32,
    /// Reserved, must be 0.
    Reserved: u32,
};

/// Hardware-dependent cursor resource.
pub const RT_CURSOR = 1;
/// Bitmap resource.
pub const RT_BITMAP = 2;
/// Hardware-dependent icon resource.
pub const RT_ICON = 3;
/// Menu resource.
pub const RT_MENU = 4;
/// Dialog box.
pub const RT_DIALOG = 5;
/// String-table entry.
pub const RT_STRING = 6;
/// Font directory resource.
pub const RT_FONTDIR = 7;
/// Font resource.
pub const RT_FONT = 8;
/// Accelerator table.
pub const RT_ACCELERATOR = 9;
/// Application-defined resource (raw data).
pub const RT_RCDATA = 10;
/// Message-table entry.
pub const RT_MESSAGETABLE = 11;
/// Hardware-independent cursor resource.
pub const RT_GROUP_CURSOR = 12;
/// Hardware-independent icon resource.
pub const RT_GROUP_ICON = 14;
/// Version resource.
pub const RT_VERSION = 16;
/// Dialog include.
pub const RT_DLGINCLUDE = 17;
/// Plug and Play resource.
pub const RT_PLUGPLAY = 19;
/// VXD.
pub const RT_VXD = 20;
/// Animated cursor.
pub const RT_ANICURSOR = 21;
/// Animated icon.
pub const RT_ANIICON = 22;
/// HTML resource.
pub const RT_HTML = 23;
/// Side-by-side assembly manifest.
pub const RT_MANIFEST = 24;

/// Menu item template header.
pub const MENUITEMTEMPLATEHEADER = extern struct {
    /// The version number of the menu template. Usually 0.
    versionNumber: u16,
    /// The offset from the end of the header. Usually 0.
    offset: u16,
};

/// Dialog box template.
pub const DLGTEMPLATE = extern struct {
    /// The style of the dialog box.
    style: u32,
    /// The extended style of the dialog box.
    dwExtendedStyle: u32,
    /// The number of items in the dialog box.
    cdit: u16,
    /// The x-coordinate of the upper-left corner of the dialog box.
    x: i16,
    /// The y-coordinate of the upper-left corner of the dialog box.
    y: i16,
    /// The width of the dialog box.
    cx: i16,
    /// The height of the dialog box.
    cy: i16,
    // Variable length stuff follows: menu, class, title (null terminated utf-16 strings)
};
