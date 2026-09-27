# Web UI HTTP and WebSocket protocol

The native build serves the browser UI from `http://127.0.0.1:1995`. Two
surfaces live there: a read-only static file server and one WebSocket endpoint
carrying the emulator's live state. The handler is `src/gui/web_ui.zig`; the
reference client is `src/gui/app.js`.

## HTTP

| Request | Response |
| --- | --- |
| `GET /` or `GET /index.html` | The UI shell |
| `GET /<asset>` | The file under `src/gui/`, or 404 |
| `GET /ws` with `Upgrade: websocket` | 101, then the WebSocket protocol below |
| `GET /ws` without an upgrade header | 400 |
| Any other path | 403 |
| Any method other than `GET` or `HEAD` on a static path | 405 with `Allow: GET, HEAD` |
| Any method other than `GET` on `/ws` | 405 with `Allow: GET` |

The query string is stripped before routing, so `/ws?cache=1` reaches the
WebSocket endpoint and `/app.js?v=2` serves the asset.

`/ws` is an exact path. With the default bind address a browser handshake must
carry an `Origin` of `http://127.0.0.1:1995`, `http://localhost:1995`, or
`http://[::1]:1995`; any other origin gets 403. `ZINE_WEB_HOST` and
`ZINE_WEB_PORT` change the bind address and the allowed origin together, and
the `localhost` / `::1` aliases are accepted only for a loopback bind
address. A client that sends no `Origin` (curl, the test scripts) is allowed.

Every non-file response uses the same body: a plain-text reason with
`Content-Type: text/plain; charset=utf-8`. There is no JSON error envelope on
the HTTP side; the JSON envelope below belongs to the WebSocket side only.

### Static asset responses

`Content-Type` comes from the extension: `.html`, `.css`, `.js`, `.json`,
`.svg`, `.png`, `.ico`, `.wav`. Anything else is served as
`application/octet-stream`.

Assets carrying a build-time gzip variant (see `precompressedContent` in
`web_ui.zig`) are served compressed when the client's `Accept-Encoding`
negotiates gzip. `Vary: Accept-Encoding` is always sent, and the ETag covers
the representation actually sent, so a client that revalidates with
`If-None-Match` gets a 304 only for the encoding it asked for. A 304 repeats
`ETag`, `Cache-Control: no-cache`, `Vary`, and `Content-Encoding: gzip` when
the revalidated representation was compressed. `Cache-Control: private, no-cache`
forces revalidation, so an edited asset is picked up on the next load.

Assets over 10 MiB are refused with 413.

## WebSocket messages

One JSON object per text message, discriminated by a string `type`. The server
pushes three kinds of frame:

- Binary, `width * height * 4` bytes of BGRA: one screen frame.
- Binary, 4-byte `AUD\0` prefix then PCM: one audio buffer.
- Text, JSON: window chrome and state.

On connect the server replays its cached state (resolution, menu, title,
dialog, controls) so a reconnecting client is immediately consistent. Both
sides may then send text messages at any time.

### Server to client

| `type` | Payload |
| --- | --- |
| `set_resolution` | `width`, `height` |
| `menu` | `menu` |
| `check_menu_item`, `enable_menu_item` | `id`, `checked` / `enabled` |
| `set_title` | `text` |
| `set_window_pos` | `cx`, `cy` (window origin), `clientW`, `clientH` (client area) |
| `set_statusbar_text`, `set_statusbar_parts` | status bar text; `set_statusbar_parts` carries only `count` |
| `set_clipboard` | `text` |
| `set_volume` | `volume` (0-100) |
| `audio_format` | `sampleRate`, `channels`, `bitsPerSample` |
| `directory_listing` | answer to `browse_directory` |
| `desktop_icons`, `set_icon` | desktop icon geometry |
| `open_file_dialog`, `open_find_dialog`, `open_font_dialog`, `open_print_dialog`, `show_page_setup_dialog`, `show_print_dialog`, `show_color_dialog`, `show_context_menu`, `message_box` | dialog requests |
| `show_controls`, `add_control`, `set_control_checked`, `set_control_color`, `set_listbox_items`, `update_control_range`, `update_control_text`, `update_control_value` | guest control state |
| `show_edit_control`, `set_edit_text`, `set_edit_font`, `resize_edit_control`, `edit_setsel`, `edit_replacesel`, `edit_scrollcaret`, `edit_undo` | guest edit control state |
| `close_dialog`, `custom_dialog` | dialog lifecycle |
| `error` | `message`: see below |

### Client to server

A message the server cannot act on is answered with
`{"type":"error","message":"..."}` and otherwise ignored. That covers malformed
JSON, a body that is not an object, a missing or non-string `type`, an unknown
`type`, a missing required field, and a field of the wrong JSON type. The
connection stays open either way.

| `type` | Fields |
| --- | --- |
| `command` | `id` (integer, required) |
| `keydown`, `keyup` | `key` (string, required; a `KeyboardEvent.code` with no Win32 equivalent is ignored, not an error) |
| `mousedown`, `mouseup`, `mousemove` | `x`, `y` (integers, required), `button` (integer, default 0) |
| `wheel` | `delta` (integer, required) |
| `resize` | `clientW`, `clientH` (integers, required), `sizeType` (integer, default 0) |
| `close` | none |
| `open_file` | `filename` (string, required), `dir` (string, default `Desktop`) |
| `browse_directory` | `path` (string, required) |
| `launch` | `path` (string, required) |
| `find_action` | `action`, `findText` (strings, required), `replaceText` (string, default `""`), `matchCase` (bool, default false), `searchDown` (bool, default true) |
| `font_chosen` | `face` (string, required), `size` (integer, required), `bold`, `italic` (bools, default false) |
| `print_chosen` | `from`, `to` (integers, required), `copies` (integer, default 1) |
| `page_setup_chosen` | `left`, `top` (integers, required), `right`, `bottom`, `paperW`, `paperH`, `orientation` (integers, default 0/0/8500/11000/0) |
| `color_selected` | `color` (integer `0xRRGGBB`; negative means cancel) |
| `listbox_select` | `id`, `index` (integers, required) |
| `context_menu_select` | `id` (integer, required; 0 dismisses the menu) |
| `cancel_dialog` | none |
| `text_sync` | `text` (string, required, at most 65536 bytes) |
| `clipboard_sync` | `text` (string, required, at most 65536 bytes) |
| `set_volume` | `volume` (integer percent, clamped to 0-100) |

### Paths

`open_file`, `launch`, and `browse_directory` all resolve inside the virtual
`drive_c/`. A path that is absolute, drive-qualified, or reaches outside the
root is refused: the first two with `{"type":"error"}`, the third by
`renderer.listDirectory`, which reports an empty listing.
