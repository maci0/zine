//! The web UI assets the build embeds, and what the server does with each.
//!
//! One list, read by the build (which digests and compresses the bytes) and by
//! the server (which routes a digested URL back to them), so an asset cannot
//! be embedded without being served, or named by the document without a route
//! to it.
//!
//! The order is the order the bytes are produced in, and it is a dependency
//! order: the script and the document name the assets above them by digest, so
//! each asset's bytes are rewritten with the digests of the ones already
//! listed. The document is last because it names the script.
//!
//! `precompress` marks the assets worth a gzip variant. An icon is a few
//! hundred bytes of already-compact markup, and the server sends whichever of
//! the two representations is smaller, so compressing one only grows the
//! binary.

pub const Asset = struct {
    /// Path under `src/gui`, and the name the build's options module carries
    /// the bytes and the digest under.
    path: []const u8,
    /// Whether the server may offer a gzip variant, precompressed here.
    precompress: bool,
    /// Whether the document names this asset by digest. The document itself
    /// cannot: it is what names the others.
    digested_url: bool,
};

pub const assets = [_]Asset{
    // Icons first: the script names them by digest, and its own digest covers
    // the rewritten names.
    .{ .path = "assets/back.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/up.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/folder.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/file.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/exe.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/gb.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/desktop.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/favicon.svg", .precompress = false, .digested_url = true },
    .{ .path = "assets/start.svg", .precompress = false, .digested_url = true },
    .{ .path = "app.js", .precompress = true, .digested_url = true },
    .{ .path = "win2k.css", .precompress = true, .digested_url = true },
    .{ .path = "van.min.js", .precompress = true, .digested_url = true },
    .{ .path = "index.html", .precompress = true, .digested_url = false },
};

/// The document the server serves: the build's, with every digested asset it
/// names rewritten to its content-addressed URL. It has no digested URL of its
/// own, so it is served under this name rather than under `path`.
pub const document_option = "index_html";
