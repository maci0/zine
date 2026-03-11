'use strict';

const {div, span, button, input, select, option, label, fieldset, legend,
       p, u, textarea, img} = van.tags;

// --- DOM References ---
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const statusEl = document.getElementById('status');
const menuBar = document.getElementById('menu-bar');
const dialogOverlay = document.getElementById('dialog-overlay');
const mainWindow = document.getElementById('main-window');

// --- Reactive State ---
let ws;
let currentRenderWidth = 1;
let currentRenderHeight = 1;
const appIconUrl = van.state("");
const hasEditControl = van.state(false);
let currentMenuData = null;

// --- Audio ---
let audioCtx = null;
let audioProcessor = null;
let audioGainNode = null;
let audioSampleRate = 44100;
let audioChannels = 2;
let audioBitsPerSample = 16;
const audioVolume = van.state(1.0);
const audioMuted = van.state(false);
const AUDIO_RING_SIZE = 131072;
let audioRing = new Float32Array(AUDIO_RING_SIZE);
let audioRingW = 0;
let audioRingR = 0;

function setupAudio(sampleRate, channels, bitsPerSample) {
    audioSampleRate = sampleRate;
    audioChannels = channels;
    audioBitsPerSample = bitsPerSample;
    if (audioCtx) { audioCtx.close(); audioCtx = null; }
    audioCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: sampleRate });
    audioGainNode = audioCtx.createGain();
    audioGainNode.gain.value = audioMuted.val ? 0.0 : audioVolume.val;
    audioProcessor = audioCtx.createScriptProcessor(4096, 0, channels);
    audioProcessor.onaudioprocess = function(e) {
        var nch = e.outputBuffer.numberOfChannels;
        var len = e.outputBuffer.getChannelData(0).length;
        var needed = len * nch;
        var avail = (audioRingW - audioRingR + AUDIO_RING_SIZE) % AUDIO_RING_SIZE;
        if (avail < needed) {
            for (var ch = 0; ch < nch; ch++) e.outputBuffer.getChannelData(ch).fill(0);
            return;
        }
        for (var i = 0; i < len; i++) {
            for (var ch = 0; ch < nch; ch++) {
                e.outputBuffer.getChannelData(ch)[i] = audioRing[audioRingR];
                audioRingR = (audioRingR + 1) % AUDIO_RING_SIZE;
            }
        }
    };
    audioProcessor.connect(audioGainNode);
    audioGainNode.connect(audioCtx.destination);
    audioCtx.resume().catch(function(){});
}

function handleAudioData(data) {
    if (!audioCtx) return;
    if (audioBitsPerSample === 16) {
        var view = new DataView(data.buffer, data.byteOffset, data.byteLength);
        var count = Math.floor(data.byteLength / 2);
        for (var i = 0; i < count; i++) {
            audioRing[audioRingW] = view.getInt16(i * 2, true) / 32768.0;
            audioRingW = (audioRingW + 1) % AUDIO_RING_SIZE;
        }
    } else if (audioBitsPerSample === 8) {
        for (var i = 0; i < data.byteLength; i++) {
            audioRing[audioRingW] = (data[i] - 128) / 128.0;
            audioRingW = (audioRingW + 1) % AUDIO_RING_SIZE;
        }
    }
}

function resumeAudio() {
    if (audioCtx && audioCtx.state === 'suspended') audioCtx.resume();
}
document.addEventListener('click', resumeAudio);
document.addEventListener('keydown', resumeAudio);

// --- Clock ---
function updateClock() {
    const now = new Date();
    document.getElementById('taskbar-clock').textContent =
        now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
updateClock();
setInterval(updateClock, 30000);

// --- Window Dragging ---
function makeDraggable(titlebar, windowElement) {
    let isDragging = false;
    let dragOffsetX = 0;
    let dragOffsetY = 0;

    titlebar.addEventListener('mousedown', (e) => {
        if (e.target.classList.contains('win2k-titlebar-btn')) return;
        isDragging = true;

        const rect = windowElement.getBoundingClientRect();
        windowElement.style.transform = 'none';
        windowElement.style.left = rect.left + 'px';
        windowElement.style.top = rect.top + 'px';

        dragOffsetX = e.clientX - rect.left;
        dragOffsetY = e.clientY - rect.top;
        e.preventDefault();
    });

    document.addEventListener('mousemove', (e) => {
        if (isDragging) {
            windowElement.style.left = (e.clientX - dragOffsetX) + 'px';
            windowElement.style.top = (e.clientY - dragOffsetY) + 'px';
        }
    });

    document.addEventListener('mouseup', () => { isDragging = false; });
}

makeDraggable(document.getElementById('main-titlebar'), mainWindow);
makeDraggable(document.getElementById('dialog-titlebar'), dialogOverlay);

// --- Window Resize ---
(function() {
    let resizing = false;
    let resizeDir = '';
    let startX, startY, startRect;
    const MIN_W = 112;  // SM_CXMINTRACK
    const MIN_H = 27;   // SM_CYMINTRACK

    mainWindow.querySelectorAll('.resize-handle').forEach(handle => {
        handle.addEventListener('mousedown', (e) => {
            if (isMaximized) return;
            resizing = true;
            resizeDir = handle.dataset.dir;
            startX = e.clientX;
            startY = e.clientY;
            const r = mainWindow.getBoundingClientRect();
            mainWindow.style.transform = 'none';
            mainWindow.style.left = r.left + 'px';
            mainWindow.style.top = r.top + 'px';
            mainWindow.style.width = r.width + 'px';
            mainWindow.style.height = r.height + 'px';
            startRect = { x: r.left, y: r.top, w: r.width, h: r.height };
            e.preventDefault();
            e.stopPropagation();
        });
    });

    document.addEventListener('mousemove', (e) => {
        if (!resizing) return;
        const dx = e.clientX - startX;
        const dy = e.clientY - startY;
        let x = startRect.x, y = startRect.y, w = startRect.w, h = startRect.h;

        if (resizeDir.includes('e')) { w = Math.max(MIN_W, startRect.w + dx); }
        if (resizeDir.includes('s')) { h = Math.max(MIN_H, startRect.h + dy); }
        if (resizeDir.includes('w')) {
            const nw = Math.max(MIN_W, startRect.w - dx);
            x = startRect.x + startRect.w - nw;
            w = nw;
        }
        if (resizeDir.includes('n')) {
            const nh = Math.max(MIN_H, startRect.h - dy);
            y = startRect.y + startRect.h - nh;
            h = nh;
        }

        mainWindow.style.left = x + 'px';
        mainWindow.style.top = y + 'px';
        mainWindow.style.width = w + 'px';
        mainWindow.style.height = h + 'px';

        // Live resize — reset canvas first so it doesn't constrain the container
        canvas.style.width = '0';
        canvas.style.height = '0';
        const container = document.getElementById('game-container');
        const cw = container.clientWidth - 4;
        const ch = container.clientHeight - 4;
        if (cw > 0 && ch > 0) {
            canvas.style.width = cw + 'px';
            canvas.style.height = ch + 'px';
            sendWmSize(cw, ch, 0);
        }
    });

    document.addEventListener('mouseup', () => {
        resizing = false;
    });
})();

// --- Dialog Management ---
function showDialog(title, content) {
    const dialogContent = document.getElementById('dialog-content');
    document.getElementById('dialog-title').innerText = title;

    // Accept either a DOM node or an HTML string
    if (typeof content === 'string') {
        dialogContent.innerHTML = content;
    } else {
        dialogContent.innerHTML = '';
        dialogContent.appendChild(content);
    }

    dialogOverlay.style.display = 'flex';
    dialogOverlay.style.transform = 'translate(-50%, -50%)';
    dialogOverlay.style.left = '50%';
    dialogOverlay.style.top = '50%';
    dialogOverlay.style.width = '';
    dialogOverlay.style.zIndex = 3000;

    document.getElementById('main-titlebar').classList.add('inactive');
}

function closeDialog(suppressBackend = false) {
    dialogOverlay.style.display = 'none';
    document.getElementById('main-titlebar').classList.remove('inactive');
    if (!suppressBackend && ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'cancel_dialog' }));
    }
}

// --- Window State (Minimize / Maximize / Close) ---
let isMinimized = false;
let isMaximized = false;
let restoreRect = null;

function minimizeWindow() {
    if (!isMinimized) {
        isMinimized = true;
        mainWindow.style.display = 'none';
        document.getElementById('taskbar-app-btn').classList.remove('active');
    }
}

function sendWmSize(clientW, clientH, sizeType) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize', clientW, clientH, sizeType }));
    }
}

function maximizeWindow() {
    if (isMaximized) {
        if (restoreRect) {
            mainWindow.style.transform = 'none';
            mainWindow.style.left = restoreRect.x + 'px';
            mainWindow.style.top = restoreRect.y + 'px';
            mainWindow.style.width = restoreRect.w + 'px';
            mainWindow.style.height = restoreRect.h + 'px';
            canvas.style.width = restoreRect.clientW + 'px';
            canvas.style.height = restoreRect.clientH + 'px';
            sendWmSize(restoreRect.clientW, restoreRect.clientH, 0);
        }
        isMaximized = false;
    } else {
        const rect = mainWindow.getBoundingClientRect();
        const cw = parseInt(canvas.style.width) || canvas.width;
        const ch = parseInt(canvas.style.height) || canvas.height;
        restoreRect = { x: rect.left, y: rect.top, w: rect.width, h: rect.height, clientW: cw, clientH: ch };

        mainWindow.style.transform = 'none';
        mainWindow.style.left = '0px';
        mainWindow.style.top = '0px';
        mainWindow.style.width = '100vw';
        mainWindow.style.height = 'calc(100vh - 30px)';
        isMaximized = true;

        requestAnimationFrame(() => {
            const container = document.getElementById('game-container');
            const newCW = container.clientWidth - 4;
            const newCH = container.clientHeight - 4;
            if (newCW > 0 && newCH > 0) {
                canvas.style.width = newCW + 'px';
                canvas.style.height = newCH + 'px';
                sendWmSize(newCW, newCH, 2);
            }
        });
    }
}

function closeWindow() {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'close' }));
    }
}

// --- Taskbar ---
document.getElementById('taskbar-app-btn').addEventListener('click', () => {
    if (isMinimized) {
        isMinimized = false;
        mainWindow.style.display = 'flex';
        document.getElementById('taskbar-app-btn').classList.add('active');
    }
});

// --- Menu Helpers ---

/** Parse "&File" → DOM fragment with <u>F</u>ile */
function menuLabel(name) {
    const frag = document.createDocumentFragment();
    const parts = name.split(/&([A-Za-z0-9])/);
    for (let i = 0; i < parts.length; i++) {
        if (i % 2 === 0) {
            if (parts[i]) frag.appendChild(document.createTextNode(parts[i]));
        } else {
            frag.appendChild(u(parts[i]));
        }
    }
    return frag;
}

/** Send a WM_COMMAND to the backend */
function sendCommand(id) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'command', id }));
    }
}

/** Build a single popup menu item (VanJS node) */
function PopupItem(sub, onAfterClick) {
    if (!sub.name || sub.name === '') {
        return div({class: 'popup-separator'});
    }
    return div({class: 'popup-item', onclick: (e) => {
        e.stopPropagation();
        sendCommand(sub.id);
        if (onAfterClick) onAfterClick();
    }}, menuLabel(sub.name));
}

// --- Menu Rendering ---
function renderMenu(menuData) {
    currentMenuData = menuData;
    menuBar.innerHTML = '';
    menuData.forEach(item => {
        let menuItem;
        if (item.popup) {
            const popup = div({class: 'popup-menu'},
                ...item.popup.map(sub => PopupItem(sub, () => {
                    popup.style.display = 'none';
                    setTimeout(() => popup.style.display = '', 100);
                }))
            );
            menuItem = div({class: 'menu-item'}, menuLabel(item.name), popup);
        } else {
            menuItem = div({class: 'menu-item', onclick: (e) => {
                e.stopPropagation();
                sendCommand(item.id);
            }}, menuLabel(item.name));
        }
        van.add(menuBar, menuItem);
    });
}

// --- Context Menu (Taskbar right-click) ---
document.getElementById('taskbar-app-btn').addEventListener('contextmenu', (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!currentMenuData || currentMenuData.length === 0) return;

    const ctxMenu = document.getElementById('taskbar-context-menu');
    ctxMenu.innerHTML = '';

    currentMenuData.forEach((topItem, idx) => {
        if (idx > 0) van.add(ctxMenu, div({class: 'popup-separator'}));

        if (topItem.popup && topItem.popup.length > 0) {
            van.add(ctxMenu, div({class: 'popup-header'}, topItem.name.replace(/&/g, '')));
            topItem.popup.forEach(sub => {
                van.add(ctxMenu, PopupItem(sub, () => ctxMenu.style.display = 'none'));
            });
        } else {
            van.add(ctxMenu, div({class: 'popup-item', onclick: () => {
                ctxMenu.style.display = 'none';
                sendCommand(topItem.id);
            }}, menuLabel(topItem.name)));
        }
    });

    ctxMenu.style.display = 'block';
    const btnRect = e.currentTarget.getBoundingClientRect();
    const menuRect = ctxMenu.getBoundingClientRect();
    let left = btnRect.left;
    if (left + menuRect.width > window.innerWidth) {
        left = window.innerWidth - menuRect.width - 2;
    }
    ctxMenu.style.left = Math.max(0, left) + 'px';
    ctxMenu.style.bottom = (window.innerHeight - btnRect.top + 2) + 'px';
    ctxMenu.style.top = 'auto';
});

// Dismiss context menus on outside clicks
document.addEventListener('click', (e) => {
    const ctxMenu = document.getElementById('taskbar-context-menu');
    if (ctxMenu.style.display === 'block' && !ctxMenu.contains(e.target)) {
        ctxMenu.style.display = 'none';
    }
});
document.addEventListener('contextmenu', (e) => {
    const ctxMenu = document.getElementById('taskbar-context-menu');
    if (ctxMenu.style.display === 'block' && !ctxMenu.contains(e.target) &&
        !document.getElementById('taskbar-app-btn').contains(e.target)) {
        ctxMenu.style.display = 'none';
    }
});

// --- Dialog Control Rendering (VanJS) ---
function DialogControl(item, scaleX, scaleY) {
    const px = Math.round(item.x * scaleX);
    const py = Math.round(item.y * scaleY);
    const pcx = Math.round(item.cx * scaleX);
    const pcy = Math.round(item.cy * scaleY);
    const cls = item.class || '';
    const sty = item.style || 0;
    const absPos = `position:absolute; left:${px}px; top:${py}px; width:${pcx}px; height:${pcy}px;`;

    // Button
    if (cls === 'Button') {
        const bsType = sty & 0xF;
        if (bsType === 7) {
            // BS_GROUPBOX
            return fieldset({style: absPos + ' border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow); margin:0; padding:4px;'},
                legend({style: 'font-size:11px; padding:0 4px; color:black;'}, item.text)
            );
        }
        return button({class: 'win2k-button', style: absPos, "data-id": item.id, onclick: () => sendCommand(item.id)}, item.text);
    }

    // Static
    if (cls === 'Static') {
        const ssType = sty & 0x1F;
        if (ssType === 3 || ssType === 14 || ssType === 0xE) {
            if (ssType === 3 && appIconUrl.val !== "") {
                return div({style: absPos + ` background-image:url('${appIconUrl.val}'); background-size:contain; background-repeat:no-repeat; background-position:center;`});
            }
            return div({style: absPos + ' border-top:1px solid var(--sys-shadow); border-left:1px solid var(--sys-shadow); border-right:1px solid var(--sys-hilight); border-bottom:1px solid var(--sys-hilight); background:var(--sys-face);'});
        }
        if (ssType >= 0x10 && ssType <= 0x12) {
            return div({style: absPos + ' border-top:1px solid var(--sys-shadow); border-left:1px solid var(--sys-shadow); border-right:1px solid var(--sys-hilight); border-bottom:1px solid var(--sys-hilight);'});
        }
        const align = (ssType === 1) ? 'text-align:center;' : '';
        return div({style: absPos + ` ${align} white-space:pre-wrap; overflow:hidden; font-size:11px; line-height:1.3;`, "data-id": item.id}, item.text);
    }

    // Edit
    if (cls === 'Edit') {
        return input({type: 'text', class: 'win2k-edit', style: absPos, value: item.text, "data-id": item.id});
    }

    // ListBox
    if (cls === 'ListBox') {
        return div({class: 'win2k-listbox', style: absPos});
    }

    // ComboBox
    if (cls === 'ComboBox') {
        return select({class: 'win2k-edit', style: absPos});
    }

    // SysTabControl32
    if (cls === 'SysTabControl32') {
        return div({"data-id": item.id, class: 'win2k-tab-control', style: absPos},
            div({class: 'tab-header-row'}), div({class: 'tab-content'}));
    }

    // SysListView32
    if (cls === 'SysListView32' || cls === 'SysListView') {
        return div({"data-id": item.id, class: 'win2k-listview', style: absPos});
    }

    // msctls_statusbar32
    if (cls === 'msctls_statusbar32') {
        return div({"data-id": item.id, class: 'win2k-statusbar',
            style: `position:absolute; left:0; bottom:0; right:0; height:${pcy || 20}px;`});
    }

    // msctls_progress32
    if (cls === 'msctls_progress32') {
        return div({"data-id": item.id, class: 'win2k-progress', style: absPos},
            div({class: 'win2k-progress-fill'}));
    }

    // SysTreeView32
    if (cls === 'SysTreeView32') {
        return div({"data-id": item.id, class: 'win2k-treeview', style: absPos});
    }

    // Fallback
    if (item.text && item.text !== '') {
        if (item.id === 1 || item.id === 2 || item.text === 'OK' || item.text === 'Cancel') {
            return button({class: 'win2k-button', style: absPos, "data-id": item.id, onclick: () => { closeDialog(); sendCommand(item.id); }}, item.text);
        }
        return div({style: absPos + ' white-space:pre-wrap; overflow:hidden; font-size:11px; line-height:1.3;'}, item.text);
    }

    return div({style: absPos + ' border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow);', "data-id": item.id});
}

// --- Volume Control ---
function toggleVolumePopup(e) {
    e.stopPropagation();
    var popup = document.getElementById('volume-popup');
    popup.style.display = popup.style.display === 'flex' ? 'none' : 'flex';
}

document.addEventListener('click', function(e) {
    var popup = document.getElementById('volume-popup');
    if (popup.style.display === 'flex' && !popup.contains(e.target) &&
        !document.getElementById('tray-volume').contains(e.target)) {
        popup.style.display = 'none';
    }
});

function updateVolumeIcon() {
    var muted = audioMuted.val || audioVolume.val === 0;
    document.getElementById('vol-wave1').style.display = (!muted && audioVolume.val > 0.1) ? '' : 'none';
    document.getElementById('vol-wave2').style.display = (!muted && audioVolume.val > 0.5) ? '' : 'none';
    document.getElementById('vol-mute-line').style.display = muted ? '' : 'none';
}

function applyVolume() {
    if (audioGainNode) {
        audioGainNode.gain.value = audioMuted.val ? 0.0 : audioVolume.val;
    }
    updateVolumeIcon();
}

function onVolumeSliderChange(val) {
    audioVolume.val = parseInt(val) / 100.0;
    applyVolume();
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'set_volume', volume: parseInt(val) }));
    }
}

function onMuteToggle(checked) {
    audioMuted.val = checked;
    applyVolume();
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'set_volume', volume: checked ? 0 : Math.round(audioVolume.val * 100) }));
    }
}

// --- Helper: ensure controls container exists ---
function getOrCreateControlsContainer() {
    canvas.style.display = 'none';
    let c = document.getElementById('controls-container');
    if (!c) {
        c = document.createElement('div');
        c.id = 'controls-container';
        c.style.position = 'relative';
        c.style.width = '100%';
        c.style.height = '100%';
        c.style.backgroundColor = 'var(--sys-face)';
        c.style.overflow = 'hidden';
        canvas.parentElement.appendChild(c);
    }
    return c;
}

// --- WebSocket Connection ---
function connect() {
    ws = new WebSocket(`ws://${window.location.host}/ws`);
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
        statusEl.style.display = 'none';

        closeDialog(true);
        menuBar.innerHTML = '';

        if (hasEditControl.val) {
            hasEditControl.val = false;
        }

        const inset = document.querySelector('.canvas-inset');
        if (inset) {
            inset.style.width = '';
            inset.style.height = '';
        }

        if (isMaximized) {
            const container = document.getElementById('game-container');
            const cw = container.clientWidth - 4;
            const ch = container.clientHeight - 4;
            if (cw > 0 && ch > 0) {
                sendWmSize(cw, ch, 2);
            }
        }
    };

    ws.onclose = () => {
        statusEl.style.display = 'block';
        statusEl.innerText = "Disconnected. Reconnecting...";
        statusEl.style.color = "#f87171";
        setTimeout(connect, 1000);
    };

    ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
            const view = new Uint8Array(event.data);
            if (view.length >= 4 && view[0] === 0x41 && view[1] === 0x55 && view[2] === 0x44 && view[3] === 0x00) {
                handleAudioData(view.subarray(4));
            } else {
                const buffer = new Uint8ClampedArray(event.data);
                if (buffer.length === currentRenderWidth * currentRenderHeight * 4) {
                    const imageData = new ImageData(buffer, currentRenderWidth, currentRenderHeight);
                    ctx.putImageData(imageData, 0, 0);
                }
            }
        } else {
            try {
                const msg = JSON.parse(event.data);

                if (msg.type === "set_resolution") {
                    currentRenderWidth = msg.width;
                    currentRenderHeight = msg.height;
                    canvas.width = currentRenderWidth;
                    canvas.height = currentRenderHeight;

                } else if (msg.type === "menu") {
                    renderMenu(msg.menu);

                } else if (msg.type === "message_box") {
                    const mbText = (msg.text || '').replace(/\n/g, '<br>');
                    const textEl = div({style: 'padding:8px 12px; margin:0 0 12px 0;'});
                    textEl.innerHTML = mbText;
                    showDialog(msg.title,
                        div(
                            textEl,
                            div({style: 'text-align:center; padding:0 8px 4px;'},
                                button({class: 'win2k-button', onclick: () => closeDialog()}, 'OK'))
                        )
                    );

                } else if (msg.type === "custom_dialog") {
                    const scaleX = 1.5;
                    const scaleY = 1.625;
                    const dlgW = Math.round(msg.cx * scaleX);
                    const dlgH = Math.round(msg.cy * scaleY);

                    const container = div({style: `position:relative; width:${dlgW}px; height:${dlgH}px; background-color:var(--sys-face);`},
                        ...(msg.items || []).map(item => DialogControl(item, scaleX, scaleY))
                    );
                    showDialog(msg.title, container);
                    dialogOverlay.style.width = (dlgW + 14) + 'px';

                } else if (msg.type === "show_controls") {
                    const scaleX = 1.5;
                    const scaleY = 1.625;
                    const dlgW = Math.round(msg.cx * scaleX);
                    const dlgH = Math.round(msg.cy * scaleY);

                    const ctrlContainer = getOrCreateControlsContainer();
                    ctrlContainer.style.width = dlgW + 'px';
                    ctrlContainer.style.height = dlgH + 'px';
                    ctrlContainer.innerHTML = '';

                    (msg.items || []).forEach(item => {
                        van.add(ctrlContainer, DialogControl(item, scaleX, scaleY));
                    });

                    const inset = canvas.parentElement;
                    inset.style.width = dlgW + 'px';
                    inset.style.height = dlgH + 'px';

                    if (msg.title && msg.title.length > 0) {
                        document.title = msg.title;
                        document.getElementById('window-title').innerText = msg.title;
                        document.getElementById('taskbar-title').innerText = msg.title;
                    }

                } else if (msg.type === "add_control") {
                    const ctrlContainer = getOrCreateControlsContainer();
                    van.add(ctrlContainer, DialogControl({
                        id: msg.id, x: msg.x, y: msg.y, cx: msg.cx, cy: msg.cy,
                        style: msg.style, class: msg.class, text: msg.text || ''
                    }, 1, 1));

                } else if (msg.type === "update_control_text") {
                    // Update text of an existing control by its data-id attribute
                    const el = document.querySelector(`[data-id="${msg.id}"]`);
                    if (el) {
                        // Strip Win32 '&' accelerator prefix for display
                        const displayText = (msg.text || '').replace(/&([^&])/g, '$1').replace(/&&/g, '&');
                        if (el.tagName === 'BUTTON' || el.tagName === 'INPUT') {
                            el.textContent = displayText;
                        } else {
                            el.textContent = displayText;
                        }
                    }

                } else if (msg.type === "open_file_dialog") {
                    const isSave = msg.mode === 'save';
                    const dlgTitle = isSave ? 'Save As' : 'Open';
                    const dlgAction = isSave ? 'Save' : 'Open';

                    // --- File selection logic ---
                    const filenameInput = input({type: 'text', id: 'dialog_filename', class: 'win2k-edit'});
                    const fileListEl = div({class: 'win2k-edit comdlg-file-list'});

                    function selectFile(f) {
                        filenameInput.value = f;
                        fileListEl.querySelectorAll('.file-item').forEach(el => {
                            el.classList.toggle('selected', el.textContent === f);
                        });
                    }

                    function openSelectedFile() {
                        const f = filenameInput.value;
                        if (f && ws && ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({ type: 'open_file', filename: f }));
                        }
                    }

                    // Build file items
                    if (msg.files) {
                        msg.files.forEach(f => {
                            van.add(fileListEl, div({
                                class: 'file-item',
                                onclick: () => selectFile(f),
                                ondblclick: () => openSelectedFile()
                            }, img({src: 'assets/file.svg', width: 16, height: 16}), f));
                        });
                    }

                    // Build filter dropdown
                    const filterOptions = (msg.filters && msg.filters.length > 0)
                        ? msg.filters.map(f => option(f))
                        : [option('All Files (*.*)')];
                    const ftSel = select({id: 'dialog_filetype', class: 'win2k-edit'}, ...filterOptions);

                    // --- Build dialog DOM ---
                    showDialog(dlgTitle,
                        div({class: 'comdlg-body'},
                            // Toolbar row
                            div({class: 'comdlg-toolbar-row'},
                                label('Look ', u('i'), 'n:'),
                                div({class: 'win2k-edit comdlg-lookin'}, 'My Documents'),
                                div({class: 'comdlg-toolbar-btns'},
                                    div({class: 'comdlg-toolbar-btn', title: 'Go To Last Folder Visited'}, img({src: 'assets/back.svg'})),
                                    div({class: 'comdlg-toolbar-btn', title: 'Up One Level'}, img({src: 'assets/up.svg'})),
                                    div({class: 'comdlg-toolbar-sep'}),
                                    div({class: 'comdlg-toolbar-btn', title: 'Create New Folder'}, img({src: 'assets/newfolder.svg'})),
                                    div({class: 'comdlg-toolbar-sep'}),
                                    div({class: 'comdlg-toolbar-btn', title: 'Views'}, img({src: 'assets/views.svg'})))),
                            // Main area (places bar + file list)
                            div({class: 'comdlg-main'},
                                div({class: 'comdlg-places-bar'},
                                    div({class: 'comdlg-place-item', title: 'History'}, img({src: 'assets/history.svg'}), span('History')),
                                    div({class: 'comdlg-place-item', title: 'Desktop'}, img({src: 'assets/desktop.svg'}), span('Desktop')),
                                    div({class: 'comdlg-place-item active', title: 'My Documents'}, img({src: 'assets/mydocs.svg'}), span('My Documents')),
                                    div({class: 'comdlg-place-item', title: 'My Computer'}, img({src: 'assets/mypc.svg'}), span('My Computer')),
                                    div({class: 'comdlg-place-item', title: 'My Network Places'}, img({src: 'assets/network.svg'}), span('My Network P...'))),
                                fileListEl),
                            // Bottom rows
                            div({class: 'comdlg-bottom-row'},
                                label('File ', u('n'), 'ame:'),
                                filenameInput,
                                button({class: 'win2k-button', onclick: () => openSelectedFile()}, dlgAction)),
                            div({class: 'comdlg-bottom-row'},
                                label(isSave ? ['Save as ', u('t'), 'ype:'] : ['Files of ', u('t'), 'ype:']),
                                ftSel,
                                button({class: 'win2k-button', onclick: () => closeDialog()}, 'Cancel')))
                    );
                    dialogOverlay.style.width = '475px';

                } else if (msg.type === "close_dialog") {
                    dialogOverlay.style.display = 'none';

                } else if (msg.type === "set_title") {
                    document.title = msg.title;
                    document.getElementById('window-title').innerText = msg.title;
                    document.getElementById('taskbar-title').innerText = msg.title;

                } else if (msg.type === "set_window_pos") {
                    const clientWidth = msg.clientW || Math.max(1, msg.cx - 8);
                    const clientHeight = msg.clientH || Math.max(1, msg.cy - 46);

                    mainWindow.style.width = '';
                    const gameContainer = document.getElementById('game-container');
                    gameContainer.style.width = '';
                    gameContainer.style.height = '';

                    canvas.style.width = clientWidth + 'px';
                    canvas.style.height = clientHeight + 'px';

                    const inset = canvas.parentElement;
                    inset.style.width = clientWidth + 'px';
                    inset.style.height = clientHeight + 'px';

                } else if (msg.type === "set_volume") {
                    audioVolume.val = (msg.volume || 0) / 100.0;
                    document.getElementById('volume-slider').value = msg.volume || 0;
                    applyVolume();

                } else if (msg.type === "audio_format") {
                    setupAudio(msg.sampleRate, msg.channels, msg.bitsPerSample);

                } else if (msg.type === "show_edit_control") {
                    hasEditControl.val = true;
                    const editEl = document.getElementById('edit-control');
                    const inset = editEl.parentElement;
                    editEl.style.display = 'block';
                    canvas.style.display = 'none';
                    if (!inset.style.width || inset.style.width === '') {
                        inset.style.width = '100%';
                        inset.style.height = '100%';
                    }
                    editEl.focus();

                } else if (msg.type === "resize_edit_control") {
                    const editEl = document.getElementById('edit-control');
                    if (editEl) {
                        editEl.style.width = msg.width + 'px';
                        editEl.style.height = msg.height + 'px';
                        editEl.style.left = msg.x + 'px';
                        editEl.style.top = msg.y + 'px';
                    }

                } else if (msg.type === "set_icon") {
                    const iconUrl = "data:image/x-icon;base64," + msg.base64;
                    appIconUrl.val = iconUrl;
                    document.getElementById('titlebar-icon').src = iconUrl;
                    document.getElementById('titlebar-icon').style.display = 'block';
                    document.getElementById('taskbar-icon').src = iconUrl;
                    document.getElementById('taskbar-icon').style.display = 'block';

                    let link = document.querySelector("link[rel~='icon']");
                    if (!link) {
                        link = document.createElement('link');
                        link.rel = 'icon';
                        document.getElementsByTagName('head')[0].appendChild(link);
                    }
                    link.href = iconUrl;
                }
            } catch (e) {
                console.error("Failed to parse JSON", e);
            }
        }
    };
}

// --- Window Resize Event ---
window.addEventListener('resize', () => {
    if (isMaximized) {
        const container = document.getElementById('game-container');
        const cw = container.clientWidth - 4;
        const ch = container.clientHeight - 4;
        if (cw > 0 && ch > 0) {
            canvas.style.width = cw + 'px';
            canvas.style.height = ch + 'px';
            sendWmSize(cw, ch, 2);
        }
    }
});

// --- Keyboard Input ---
window.addEventListener('keydown', (e) => {
    if (hasEditControl.val && document.activeElement === document.getElementById('edit-control')) {
        if (e.ctrlKey && !e.altKey) {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type: 'keydown', key: e.code }));
            }
        }
        return;
    }
    if (e.altKey || e.code.startsWith('F') && !e.ctrlKey) e.preventDefault();
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'keydown', key: e.code }));
    }
});
window.addEventListener('keyup', (e) => {
    if (hasEditControl.val && document.activeElement === document.getElementById('edit-control')) return;
    if (e.altKey || e.code.startsWith('F') && !e.ctrlKey) e.preventDefault();
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'keyup', key: e.code }));
    }
});

// --- Initialize ---
connect();
