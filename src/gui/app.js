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
// Progress-bar state per control id: {value, min, max} -> fill width.
const controlRanges = {};
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
    // Schedule next update at the start of the next minute
    const msToNextMinute = (60 - now.getSeconds()) * 1000 - now.getMilliseconds();
    setTimeout(updateClock, msToNextMinute + 50);
}
updateClock();

// --- Window Dragging ---
function makeDraggable(titlebar, windowElement) {
    let isDragging = false;
    let dragOffsetX = 0;
    let dragOffsetY = 0;

    titlebar.addEventListener('mousedown', (e) => {
        if (e.target.closest('.win2k-titlebar-btn')) return;
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

/** Fit canvas into game-container preserving aspect ratio */
function fitCanvasToContainer() {
    // Temporarily shrink canvas so it doesn't constrain the container
    canvas.style.width = '0';
    canvas.style.height = '0';
    const container = document.getElementById('game-container');
    const maxW = container.clientWidth - 4;
    const maxH = container.clientHeight - 4;
    if (maxW <= 0 || maxH <= 0) return;

    const gameW = currentRenderWidth || 1;
    const gameH = currentRenderHeight || 1;
    const scale = Math.min(maxW / gameW, maxH / gameH);
    const w = Math.round(gameW * scale);
    const h = Math.round(gameH * scale);
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';
}

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

        // Live resize — fit canvas maintaining aspect ratio
        fitCanvasToContainer();
    });

    document.addEventListener('mouseup', () => {
        if (resizing) {
            resizing = false;
            // Send final size to guest app
            const cw = parseInt(canvas.style.width) || canvas.width;
            const ch = parseInt(canvas.style.height) || canvas.height;
            if (cw > 0 && ch > 0) sendWmSize(cw, ch, 0);
        }
    });
})();

// --- Dialog Management ---
function showDialog(title, content) {
    const dialogContent = document.getElementById('dialog-content');
    document.getElementById('dialog-title').textContent = title;

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

    // Move focus into the dialog for accessibility
    requestAnimationFrame(() => {
        const focusables = dialogOverlay.querySelectorAll('button, input, select, textarea, [tabindex]:not([tabindex="-1"])');
        if (focusables.length > 0) focusables[0].focus();
        
        // Trap focus
        dialogOverlay.onkeydown = (e) => {
            if (e.key === 'Tab') {
                const els = dialogOverlay.querySelectorAll('button, input, select, textarea, [tabindex]:not([tabindex="-1"])');
                if (els.length === 0) {
                    e.preventDefault();
                    return;
                }
                const first = els[0];
                const last = els[els.length - 1];
                if (e.shiftKey && document.activeElement === first) {
                    e.preventDefault();
                    last.focus();
                } else if (!e.shiftKey && document.activeElement === last) {
                    e.preventDefault();
                    first.focus();
                }
            }
        };
    });
}

function closeDialog(suppressBackend = false) {
    dialogOverlay.style.display = 'none';
    dialogOverlay.onkeydown = null;
    document.getElementById('main-titlebar').classList.remove('inactive');
    window._fileDialogUpdate = null; // Clean up file dialog navigation handler
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
            fitCanvasToContainer();
            const cw = parseInt(canvas.style.width) || canvas.width;
            const ch = parseInt(canvas.style.height) || canvas.height;
            if (cw > 0 && ch > 0) sendWmSize(cw, ch, 2);
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

// --- Start Menu ---
// Lists the launchable programs on the virtual Desktop so a guest can be
// started without double-clicking a desktop icon.
const startButton = document.getElementById('start-button');
const startMenu = document.getElementById('start-menu');
const LAUNCHABLE_EXTENSIONS = ['exe', 'com', 'bat', 'cmd'];
let desktopItems = [];

function launchDesktopItem(name) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({type: 'launch', path: 'Desktop/' + name}));
    }
}

function closeStartMenu() {
    startMenu.style.display = 'none';
    startButton.setAttribute('aria-expanded', 'false');
}

function renderStartMenu() {
    startMenu.innerHTML = '';
    const programs = desktopItems.filter(item =>
        !item.is_dir && LAUNCHABLE_EXTENSIONS.includes((item.ext || '').toLowerCase()));

    van.add(startMenu, div({class: 'popup-header'}, 'Programs'));
    if (programs.length === 0) {
        van.add(startMenu, div({class: 'popup-item disabled'},
            'No programs in drive_c/Desktop'));
    } else {
        programs.forEach(p => {
            van.add(startMenu, div({class: 'popup-item', onclick: () => {
                closeStartMenu();
                launchDesktopItem(p.name);
            }}, p.name));
        });
    }
    van.add(startMenu, div({class: 'popup-separator'}));
    van.add(startMenu, div({class: 'popup-item', onclick: closeStartMenu}, 'Cancel'));
}

startButton.addEventListener('click', (e) => {
    e.stopPropagation();
    if (startMenu.style.display === 'block') {
        closeStartMenu();
        return;
    }
    renderStartMenu();
    startMenu.style.display = 'block';
    startButton.setAttribute('aria-expanded', 'true');
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
    const isChecked = (sub.flags & 0x0008) !== 0; // MF_CHECKED
    const isDisabled = (sub.flags & 0x0003) !== 0; // MF_GRAYED | MF_DISABLED
    return div({class: 'popup-item' + (isChecked ? ' checked' : '') + (isDisabled ? ' disabled' : ''), role: 'menuitem', 'aria-disabled': isDisabled ? 'true' : 'false', 'data-cmd-id': sub.id, onclick: (e) => {
        e.stopPropagation();
        if (isDisabled) return;
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
            const popup = div({class: 'popup-menu', role: 'menu'},
                ...item.popup.map(sub => PopupItem(sub, () => {
                    popup.style.display = 'none';
                    setTimeout(() => popup.style.display = '', 100);
                }))
            );
            menuItem = div({class: 'menu-item', role: 'menuitem', 'aria-haspopup': 'true'}, menuLabel(item.name), popup);
        } else {
            menuItem = div({class: 'menu-item', role: 'menuitem', onclick: (e) => {
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
    if (startMenu.style.display === 'block' && !startMenu.contains(e.target) &&
        !startButton.contains(e.target)) {
        closeStartMenu();
    }
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

// Escape dismisses the topmost transient surface, in stacking order.
document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;

    if (startMenu.style.display === 'block') {
        closeStartMenu();
        return;
    }

    const volumePopup = document.getElementById('volume-popup');
    if (volumePopup && volumePopup.style.display === 'flex') {
        volumePopup.style.display = 'none';
        return;
    }

    const ctxMenu = document.getElementById('taskbar-context-menu');
    if (ctxMenu && ctxMenu.style.display === 'block') {
        ctxMenu.style.display = 'none';
        return;
    }

    const ctxOverlay = document.getElementById('context-menu-overlay');
    if (ctxOverlay) {
        ctxOverlay.remove();
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'context_menu_select', id: 0 }));
        }
        return;
    }

    const popups = document.querySelectorAll('.popup-menu');
    let closedMenu = false;
    popups.forEach(p => {
        if (window.getComputedStyle(p).display !== 'none') {
            p.style.display = 'none';
            closedMenu = true;
            // De-bounce the popup rendering bug
            setTimeout(() => p.style.display = '', 100);
        }
    });
    if (closedMenu) return;

    // Same dismissal path as the dialog's Cancel button: one cancel_dialog.
    if (window.getComputedStyle(dialogOverlay).display === 'flex') {
        closeDialog();
    }
});

// --- Dialog Control Rendering (VanJS) ---
function DialogControl(item, scaleX, scaleY, allItems = []) {
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
        if (bsType === 2 || bsType === 3) {
            // BS_CHECKBOX / BS_AUTOCHECKBOX
            return label({style: absPos + ' display:flex; align-items:center; gap:4px; font-size:11px; overflow:hidden; white-space:nowrap;'},
                input({type:'checkbox', class:'win2k-check', "data-id": item.id, style:'width:13px;height:13px;margin:0;flex:none;', onclick: (e) => { e.stopPropagation(); sendCommand(item.id); }}),
                span({style:'overflow:hidden;text-overflow:ellipsis;'}, (item.text||'').replace(/&([^&])/g,'$1').replace(/&&/g,'&'))
            );
        }
        if (bsType === 4 || bsType === 9) {
            // BS_RADIOBUTTON / BS_AUTORADIOBUTTON
            return label({style: absPos + ' display:flex; align-items:center; gap:4px; font-size:11px; overflow:hidden; white-space:nowrap;'},
                input({type:'radio', class:'win2k-check', "data-id": item.id, name:'radio-'+item.id, style:'width:13px;height:13px;margin:0;flex:none;', onclick: (e) => { e.stopPropagation(); sendCommand(item.id); }}),
                span({style:'overflow:hidden;text-overflow:ellipsis;'}, (item.text||'').replace(/&([^&])/g,'$1').replace(/&&/g,'&'))
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
        let ariaLabel = "Text input";
        const siblingLabel = allItems.find(sibling => 
            sibling.class === 'Static' && 
            Math.abs(sibling.y - item.y) < 10 && 
            sibling.x < item.x
        );
        if (siblingLabel && siblingLabel.text) {
            ariaLabel = siblingLabel.text.replace(/&/g, "");
        }
        return input({type: 'text', class: 'win2k-edit', style: absPos, value: item.text, "aria-label": ariaLabel, "data-id": item.id});
    }

    // ListBox
    if (cls === 'ListBox') {
        return div({class: 'win2k-listbox', style: absPos + ' overflow-y:auto; border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow); background:white;', "data-id": item.id});
    }

    // ComboBox
    if (cls === 'ComboBox') {
        return select({class: 'win2k-combo', style: absPos, "data-id": item.id});
    }

    // SysHeader32
    if (cls === 'SysHeader32') {
        return div({"data-id": item.id, class: 'win2k-header', style: absPos + ' display:flex; flex-direction:row; border-bottom:1px solid var(--sys-shadow); overflow:hidden;'});
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
        const sbText = (item.text || '').replace(/&([^&])/g, '$1').replace(/&&/g, '&');
        return div({"data-id": item.id, class: 'win2k-statusbar',
            style: `position:absolute; left:0; bottom:0; right:0; height:${pcy || 20}px;`},
            div({class: 'win2k-statusbar-pane'}, sbText));
    }

    // msctls_progress32
    if (cls === 'msctls_progress32') {
        return div({"data-id": item.id, class: 'win2k-progress', style: absPos},
            div({class: 'win2k-progress-fill'}));
    }

    // msctls_trackbar32
    if (cls === 'msctls_trackbar32') {
        return div({"data-id": item.id, style: absPos + ' display:flex; align-items:center; gap:4px;'},
            input({type: 'range', min: 0, max: 100, value: 0, style: 'flex:1; height:20px;', oninput: (e) => sendCommand(item.id)}),
            span({class: 'win2k-trackbar-val', style: 'font-size:11px; min-width:24px; text-align:right;'}, '0'));
    }

    // msctls_updown32
    if (cls === 'msctls_updown32') {
        return div({"data-id": item.id, class: 'win2k-updown', style: absPos + ' display:flex; align-items:center; justify-content:center; border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow); background:#fff;'},
            span({class: 'win2k-updown-val', style: 'font-size:11px;'}, '0'));
    }

    // SysDateTimePick32
    if (cls === 'SysDateTimePick32') {
        return div({"data-id": item.id, class: 'win2k-dtp', style: absPos + ' display:flex; align-items:center; justify-content:center; border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow); background:#fff;'},
            span({style: 'font-size:11px;'}, item.text || '2000-01-01'));
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
        statusEl.classList.remove('error');

        // --- Full UI reset for clean session ---
        closeDialog(true);
        closeStartMenu();
        menuBar.innerHTML = '';
        currentMenuData = null;
        desktopItems = [];
        dialogOverlay.style.display = 'none';

        // Reset window title
        document.title = 'Zine';
        const titleEl = document.getElementById('window-title');
        if (titleEl) titleEl.textContent = '';

        // Reset edit control
        if (hasEditControl.val) {
            hasEditControl.val = false;
        }
        const editCtrl = document.getElementById('edit-control');
        if (editCtrl) {
            editCtrl.value = '';
            editCtrl.style.fontFamily = '';
            editCtrl.style.fontSize = '';
            editCtrl.style.fontWeight = '';
            editCtrl.style.fontStyle = '';
            editCtrl.style.display = 'none';
        }

        // Clear in-place controls container
        const controlsContainer = document.getElementById('controls-container');
        if (controlsContainer) controlsContainer.remove();
        const dialogContent = document.getElementById('dialog-content');
        if (dialogContent) dialogContent.innerHTML = '';

        // Reset canvas inset sizing
        const inset = document.querySelector('.canvas-inset');
        if (inset) {
            inset.style.width = '';
            inset.style.height = '';
        }

        // Reset icon
        const iconEl = document.getElementById('window-icon');
        if (iconEl) iconEl.style.display = 'none';

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
        statusEl.textContent = "Disconnected. Reconnecting...";
        statusEl.classList.add('error');
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

                if (msg.type === "error") {
                    console.error("Zine API Error:", msg.message);
                    statusEl.textContent = "API Error: " + msg.message;
                    statusEl.style.display = 'block';
                    statusEl.classList.add('error');
                    setTimeout(() => statusEl.style.display = 'none', 4000);
                } else if (msg.type === "set_resolution") {
                    currentRenderWidth = msg.width;
                    currentRenderHeight = msg.height;
                    canvas.width = currentRenderWidth;
                    canvas.height = currentRenderHeight;
                    // Set initial CSS size to match pixel resolution
                    canvas.style.width = currentRenderWidth + 'px';
                    canvas.style.height = currentRenderHeight + 'px';

                } else if (msg.type === "audio_format") {
                    setupAudio(msg.sampleRate, msg.channels, msg.bitsPerSample);

                } else if (msg.type === "menu") {
                    renderMenu(msg.menu);

                } else if (msg.type === "check_menu_item") {
                    // Toggle checkmark on a menu item by command ID
                    document.querySelectorAll('.popup-item').forEach(el => {
                        if (el.dataset.cmdId == msg.id) el.classList.toggle('checked', msg.checked);
                    });
                    // Also update currentMenuData so reconnects show correct state
                    if (currentMenuData) {
                        currentMenuData.forEach(top => {
                            if (top.popup) {
                                top.popup.forEach(sub => {
                                    if (sub.id === msg.id) {
                                        if (msg.checked) sub.flags |= 0x0008;
                                        else sub.flags &= ~0x0008;
                                    }
                                });
                            }
                        });
                    }

                } else if (msg.type === "message_box") {
                    const textEl = div({style: 'padding:8px 12px; margin:0 0 12px 0;'});
                    // Safely render message text: escape HTML entities, then
                    // convert newlines to <br> elements to preserve formatting.
                    const rawText = msg.text || '';
                    rawText.split('\n').forEach((line, i) => {
                        if (i > 0) textEl.appendChild(document.createElement('br'));
                        textEl.appendChild(document.createTextNode(line));
                    });
                    showDialog(msg.title,
                        div(
                            textEl,
                            div({style: 'text-align:center; padding:0 8px 4px;'},
                                button({class: 'win2k-button', onclick: () => closeDialog()}, 'OK'))
                        )
                    );

                } else if (msg.type === "custom_dialog") {
                    const scaleX = 1.75;
                    const scaleY = 1.875;
                    const dlgW = Math.round(msg.cx * scaleX);
                    const dlgH = Math.round(msg.cy * scaleY);

                    const container = div({style: `position:relative; width:${dlgW}px; height:${dlgH}px; background-color:var(--sys-face);`},
                        ...(msg.items || []).map(item => DialogControl(item, scaleX, scaleY, msg.items))
                    );
                    showDialog(msg.title, container);
                    dialogOverlay.style.width = (dlgW + 14) + 'px';

                } else if (msg.type === "show_controls") {
                    const scaleX = 1.75;
                    const scaleY = 1.875;
                    const dlgW = Math.round(msg.cx * scaleX);
                    const dlgH = Math.round(msg.cy * scaleY);

                    const ctrlContainer = getOrCreateControlsContainer();
                    ctrlContainer.style.width = dlgW + 'px';
                    ctrlContainer.style.height = dlgH + 'px';
                    ctrlContainer.innerHTML = '';

                    (msg.items || []).forEach(item => {
                        van.add(ctrlContainer, DialogControl(item, scaleX, scaleY, msg.items));
                    });

                    const inset = canvas.parentElement;
                    inset.style.width = dlgW + 'px';
                    inset.style.height = dlgH + 'px';

                    if (msg.title && msg.title.length > 0) {
                        document.title = msg.title;
                        document.getElementById('window-title').textContent = msg.title;
                        document.getElementById('taskbar-title').textContent = msg.title;
                    }

                } else if (msg.type === "add_control") {
                    const ctrlContainer = getOrCreateControlsContainer();
                    van.add(ctrlContainer, DialogControl({
                        id: msg.id, x: msg.x, y: msg.y, cx: msg.cx, cy: msg.cy,
                        style: msg.style, class: msg.class, text: msg.text || ''
                    }, 1, 1));

                } else if (msg.type === "update_control_text") {
                    // Update text of an existing control by its data-id attribute
                    const el = Array.from(document.querySelectorAll('[data-id]')).find(e => e.dataset.id == msg.id);
                    if (el) {
                        // Strip Win32 '&' accelerator prefix for display
                        const displayText = (msg.text || '').replace(/&([^&])/g, '$1').replace(/&&/g, '&');
                        // Status bar: text goes into its pane, not the container.
                        const sbPane = el.querySelector('.win2k-statusbar-pane');
                        if (sbPane) {
                            sbPane.textContent = displayText;
                        } else {
                            el.textContent = displayText;
                        }
                    }

                } else if (msg.type === "show_color_dialog") {
                    const init = msg.initial >>> 0;
                    const toHex = (v) => v.toString(16).padStart(2, '0');
                    const initial = '#' + toHex((init >> 16) & 0xFF) + toHex((init >> 8) & 0xFF) + toHex(init & 0xFF);

                    const colorInput = input({type: 'color', value: initial,
                        style: 'width:100%; height:34px; padding:0; background:transparent; border:none;'});
                    const sendColor = () => {
                        const v = colorInput.value;
                        const r = parseInt(v.substr(1, 2), 16), g = parseInt(v.substr(3, 2), 16), b = parseInt(v.substr(5, 2), 16);
                        if (ws && ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({type: 'color_selected', color: (r << 16) | (g << 8) | b}));
                        }
                        closeDialog(true);
                    };

                    showDialog('Choose Color',
                        div({style: 'display:flex; flex-direction:column; gap:10px;'},
                            div({style: 'font-size:11px;'}, 'Color:'),
                            colorInput,
                            div({style: 'display:flex; justify-content:flex-end; gap:6px;'},
                                button({class: 'win2k-button', onclick: sendColor}, 'OK'),
                                button({class: 'win2k-button', onclick: () => {
                                    if (ws && ws.readyState === WebSocket.OPEN) {
                                        ws.send(JSON.stringify({type: 'color_selected', color: -1}));
                                    }
                                    closeDialog(true);
                                }}, 'Cancel'))));
                    dialogOverlay.style.width = '260px';

                } else if (msg.type === "set_control_color") {
                    // Background color from the parent's WM_CTLCOLOR handler.
                    const el = Array.from(document.querySelectorAll('[data-id]')).find(e => e.dataset.id == msg.id);
                    if (el) {
                        const c = msg.color >>> 0;
                        const r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
                        el.style.backgroundColor = 'rgb(' + r + ',' + g + ',' + b + ')';
                    }

                } else if (msg.type === "set_listbox_items") {
                    // Fill a listbox control with items (newline-joined string).
                    const el = Array.from(document.querySelectorAll('[data-id]')).find(e => e.dataset.id == msg.id);
                    if (el && el.classList.contains('win2k-listbox')) {
                        const items = (msg.items || '').split('\n');
                        el.innerHTML = '';
                        items.forEach((it, idx) => {
                            const d = div({class: 'win2k-listbox-item', style: 'padding:1px 4px; font-size:11px; cursor:default; white-space:nowrap; overflow:hidden;', onclick: (e) => {
                                e.stopPropagation();
                                sendCommand(msg.id);
                                if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'listbox_select', id: msg.id, index: idx}));
                            }}, it);
                            el.appendChild(d);
                        });
                    } else if (el && el.classList.contains('win2k-header')) {
                        const items = (msg.items || '').split('\n');
                        el.innerHTML = '';
                        items.forEach((it) => {
                            const d = div({class: 'win2k-header-item', style: 'padding:2px 8px; font-size:11px; font-weight:bold; border-right:1px solid var(--sys-shadow); white-space:nowrap; overflow:hidden;'}, it);
                            el.appendChild(d);
                        });
                    } else if (el && el.classList.contains('win2k-treeview')) {
                        const items = (msg.items || '').split('\n');
                        el.innerHTML = '';
                        items.forEach((it, idx) => {
                            const d = div({class: 'win2k-treeview-row', style: 'padding:1px 4px; font-size:11px; cursor:default; white-space:nowrap; overflow:hidden;', onclick: (e) => {
                                e.stopPropagation();
                                sendCommand(msg.id);
                                if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'listbox_select', id: msg.id, index: idx}));
                            }}, it);
                            el.appendChild(d);
                        });
                    } else if (el && el.classList.contains('win2k-listview')) {
                        // ListView: render items as rows
                        const items = (msg.items || '').split('\n');
                        el.innerHTML = '';
                        items.forEach((it, idx) => {
                            const d = div({class: 'win2k-listview-row', style: 'padding:1px 4px; font-size:11px; cursor:default; white-space:nowrap; overflow:hidden; border-bottom:1px solid #ddd;', onclick: (e) => {
                                e.stopPropagation();
                                sendCommand(msg.id);
                                if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'listbox_select', id: msg.id, index: idx}));
                            }}, it);
                            el.appendChild(d);
                        });
                    } else if (el && el.classList.contains('win2k-tab-control')) {
                        // Tab control: fill the header row with tab labels
                        const items = (msg.items || '').split('\n');
                        const header = el.querySelector('.tab-header-row');
                        if (header) {
                            header.innerHTML = '';
                            items.forEach((it, idx) => {
                                const t = div({class: 'win2k-tab', style: 'display:inline-block; padding:2px 10px; border:1px solid; border-color:var(--sys-hilight) var(--sys-shadow) var(--sys-shadow) var(--sys-hilight); font-size:11px; margin-right:2px; cursor:default; background:var(--sys-face);', onclick: (e) => {
                                    e.stopPropagation();
                                    sendCommand(msg.id);
                                    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'listbox_select', id: msg.id, index: idx}));
                                }}, it);
                                header.appendChild(t);
                            });
                        }
                    } else if (el && el.tagName === 'SELECT') {
                        // ComboBox: fill options
                        const items = (msg.items || '').split('\n');
                        el.innerHTML = '';
                        items.forEach((it, idx) => {
                            const o = document.createElement('option');
                            o.value = String(idx);
                            o.textContent = it;
                            el.appendChild(o);
                        });
                        el.onchange = (e) => {
                            sendCommand(msg.id);
                            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: 'listbox_select', id: msg.id, index: parseInt(el.value, 10) || 0}));
                        };
                    }

                } else if (msg.type === "set_control_checked") {
                    // Checkbox/radio checked state pushed from the backend.
                    const el = Array.from(document.querySelectorAll('[data-id]')).find(e => e.dataset.id == msg.id);
                    if (el && (el.type === 'checkbox' || el.type === 'radio')) {
                        el.checked = !!msg.checked;
                    }

                } else if (msg.type === "update_control_value" || msg.type === "update_control_range") {
                    // Progress-bar state: value (position) + range (min/max) per
                    // control id; fill width = (value - min) / (max - min).
                    const st = (controlRanges[msg.id] = controlRanges[msg.id] || {value: 0, min: 0, max: 100});
                    if (msg.type === "update_control_value") st.value = msg.value;
                    if (msg.type === "update_control_range") { st.min = msg.min; st.max = msg.max; }
                    const el = Array.from(document.querySelectorAll('[data-id]')).find(e => e.dataset.id == msg.id);
                    if (el) {
                        const fill = el.querySelector('.win2k-progress-fill');
                        if (fill) {
                            const span = (st.max - st.min) > 0 ? (st.max - st.min) : 1;
                            const pct = Math.max(0, Math.min(100, (st.value - st.min) * 100 / span));
                            fill.style.width = pct + '%';
                        }
                        const rangeEl = el.querySelector('input[type=range]');
                        if (rangeEl) {
                            rangeEl.value = st.value;
                            const valEl = el.querySelector('.win2k-trackbar-val');
                            if (valEl) valEl.textContent = String(st.value);
                        }
                        const spinEl = el.querySelector('.win2k-updown-val');
                        if (spinEl) spinEl.textContent = String(st.value);
                    }

                } else if (msg.type === "open_file_dialog") {
                    const isSave = msg.mode === 'save';
                    const dlgTitle = isSave ? 'Save As' : 'Open';
                    const dlgAction = isSave ? 'Save' : 'Open';

                    // --- Navigation state ---
                    let currentPath = msg.path || 'Desktop';
                    let pathHistory = [];

                    // --- File selection logic ---
                    const filenameInput = input({type: 'text', id: 'dialog_filename', class: 'win2k-edit'});
                    const fileListEl = div({class: 'win2k-edit comdlg-file-list'});
                    const lookInLabel = div({class: 'win2k-edit comdlg-lookin'});

                    // --- Toolbar buttons (created early so we can reference them) ---
                    const backBtn = div({class: 'comdlg-toolbar-btn', title: 'Go To Last Folder Visited',
                        onclick: () => navigateBack()}, img({src: 'assets/back.svg'}));
                    const upBtn = div({class: 'comdlg-toolbar-btn', title: 'Up One Level',
                        onclick: () => navigateUp()}, img({src: 'assets/up.svg'}));

                    function updateLookIn() {
                        // Show just the last folder name, like Windows does
                        const parts = currentPath.split('/');
                        lookInLabel.textContent = parts[parts.length - 1] || currentPath;
                    }

                    function updateToolbarState() {
                        backBtn.style.opacity = pathHistory.length > 0 ? '1' : '0.5';
                        backBtn.style.pointerEvents = pathHistory.length > 0 ? 'auto' : 'none';
                        // Disable Up when at root "Desktop"
                        const atRoot = currentPath === 'Desktop';
                        upBtn.style.opacity = atRoot ? '0.5' : '1';
                        upBtn.style.pointerEvents = atRoot ? 'none' : 'auto';
                    }

                    function selectFile(f) {
                        filenameInput.value = f;
                        fileListEl.querySelectorAll('.file-item').forEach(el => {
                            el.classList.toggle('selected', el.dataset.name === f);
                        });
                    }

                    function openSelectedFile() {
                        const f = filenameInput.value;
                        if (f && ws && ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({ type: 'open_file', filename: f, dir: currentPath }));
                        }
                    }

                    function navigateTo(newPath) {
                        pathHistory.push(currentPath);
                        currentPath = newPath;
                        updateLookIn();
                        updateToolbarState();
                        updatePlaceState();
                        filenameInput.value = '';
                        // Request directory listing from server
                        if (ws && ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({ type: 'browse_directory', path: newPath }));
                        }
                    }

                    function navigateBack() {
                        if (pathHistory.length === 0) return;
                        currentPath = pathHistory.pop();
                        updateLookIn();
                        updateToolbarState();
                        updatePlaceState();
                        filenameInput.value = '';
                        if (ws && ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({ type: 'browse_directory', path: currentPath }));
                        }
                    }

                    function navigateUp() {
                        const parts = currentPath.split('/');
                        if (parts.length <= 1) return; // Already at root
                        const parentPath = parts.slice(0, -1).join('/');
                        navigateTo(parentPath);
                    }

                    function populateFileList(folders, files) {
                        fileListEl.innerHTML = '';
                        // Folders first
                        if (folders) {
                            folders.forEach(f => {
                                const item = div({
                                    class: 'file-item',
                                    'data-name': f,
                                    'data-type': 'folder',
                                    onclick: () => selectFile(f),
                                    ondblclick: () => navigateTo(currentPath + '/' + f)
                                }, img({src: 'assets/folder.svg', width: 16, height: 16}), f);
                                van.add(fileListEl, item);
                            });
                        }
                        // Then files
                        if (files) {
                            files.forEach(f => {
                                van.add(fileListEl, div({
                                    class: 'file-item',
                                    'data-name': f,
                                    'data-type': 'file',
                                    onclick: () => selectFile(f),
                                    ondblclick: () => { selectFile(f); openSelectedFile(); }
                                }, img({src: 'assets/file.svg', width: 16, height: 16}), f));
                            });
                        }
                    }

                    // Store handler on the dialog so directory_listing messages can find it
                    window._fileDialogUpdate = function(folders, files, path) {
                        if (path !== undefined) currentPath = path;
                        populateFileList(folders, files);
                        updateLookIn();
                        updateToolbarState();
                        updatePlaceState();
                    };

                    // Populate initial listing
                    populateFileList(msg.folders, msg.files);
                    updateLookIn();
                    updateToolbarState();

                    // Build filter dropdown
                    const filterOptions = (msg.filters && msg.filters.length > 0)
                        ? msg.filters.map(f => option(f))
                        : [option('All Files (*.*)')];
                    const ftSel = select({id: 'dialog_filetype', class: 'win2k-edit'}, ...filterOptions);

                    // --- Places bar ---
                    // The guest browses drive_c/Desktop, so only that place has
                    // a backing path. The other Win2K places are not listed.
                    const placeItems = [];
                    function makePlace(title, iconSrc, targetPath) {
                        const el = div({
                            class: 'comdlg-place-item', title: title,
                            onclick: () => { if (currentPath !== targetPath) navigateTo(targetPath); }
                        }, img({src: iconSrc}), span(title));
                        placeItems.push({el: el, path: targetPath});
                        return el;
                    }

                    function updatePlaceState() {
                        placeItems.forEach(p => p.el.classList.toggle('active', currentPath === p.path));
                    }

                    // --- Build dialog DOM ---
                    showDialog(dlgTitle,
                        div({class: 'comdlg-body'},
                            // Toolbar row
                            div({class: 'comdlg-toolbar-row'},
                                label('Look ', u('i'), 'n:'),
                                lookInLabel,
                                div({class: 'comdlg-toolbar-btns'},
                                    backBtn,
                                    upBtn)),
                            // Main area (places bar + file list)
                            div({class: 'comdlg-main'},
                                div({class: 'comdlg-places-bar'},
                                    makePlace('Desktop', 'assets/desktop.svg', 'Desktop')),
                                fileListEl),
                            // Bottom rows
                            div({class: 'comdlg-bottom-row'},
                                label('File ', u('n'), 'ame:'),
                                filenameInput,
                                button({class: 'win2k-button', onclick: () => {
                                    // If a folder name is typed, navigate into it
                                    const val = filenameInput.value;
                                    const folderItem = Array.from(fileListEl.querySelectorAll('.file-item[data-type="folder"]')).find(el => el.dataset.name === val);
                                    if (folderItem) {
                                        navigateTo(currentPath + '/' + val);
                                        return;
                                    }
                                    openSelectedFile();
                                }}, dlgAction)),
                            div({class: 'comdlg-bottom-row'},
                                label(isSave ? ['Save as ', u('t'), 'ype:'] : ['Files of ', u('t'), 'ype:']),
                                ftSel,
                                button({class: 'win2k-button', onclick: () => closeDialog()}, 'Cancel')))
                    );
                    dialogOverlay.style.width = '475px';
                    updatePlaceState();

                } else if (msg.type === "directory_listing") {
                    // Server response to browse_directory — update the file dialog
                    if (window._fileDialogUpdate) {
                        window._fileDialogUpdate(msg.folders, msg.files, msg.path);
                    }

                } else if (msg.type === "open_font_dialog") {
                    // --- Font Dialog ---
                    const fonts = [
                        'Arial', 'Arial Black', 'Comic Sans MS', 'Courier New',
                        'Fixedsys', 'Georgia', 'Impact', 'Lucida Console',
                        'Microsoft Sans Serif', 'MS Sans Serif', 'Palatino Linotype',
                        'System', 'Tahoma', 'Terminal', 'Times New Roman',
                        'Trebuchet MS', 'Verdana'
                    ];
                    const styles = ['Regular', 'Italic', 'Bold', 'Bold Italic'];
                    const sizes = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72];

                    let selFont = msg.face || 'Lucida Console';
                    let selSize = msg.size || 10;
                    let selBold = msg.bold || false;
                    let selItalic = msg.italic || false;

                    function getStyleIdx() {
                        if (selBold && selItalic) return 3;
                        if (selBold) return 2;
                        if (selItalic) return 1;
                        return 0;
                    }

                    const fontInput = input({type: 'text', class: 'win2k-edit', value: selFont, style: 'width:160px; height:21px;'});
                    const styleInput = input({type: 'text', class: 'win2k-edit', value: styles[getStyleIdx()], style: 'width:100px; height:21px;'});
                    const sizeInput = input({type: 'text', class: 'win2k-edit', value: String(selSize), style: 'width:50px; height:21px;'});

                    const previewEl = div({class: 'fontdlg-preview', style: 'min-height:60px;'}, 'AaBbYyZz');

                    function updatePreview() {
                        previewEl.style.fontFamily = "'" + selFont + "', sans-serif";
                        previewEl.style.fontSize = Math.min(selSize, 48) + 'pt';
                        previewEl.style.fontWeight = selBold ? 'bold' : 'normal';
                        previewEl.style.fontStyle = selItalic ? 'italic' : 'normal';
                    }

                    function selectListItem(listEl, value) {
                        listEl.querySelectorAll('.fontdlg-list-item').forEach(el => {
                            el.classList.toggle('selected', el.textContent === String(value));
                            if (el.textContent === String(value)) {
                                el.scrollIntoView({block: 'nearest'});
                            }
                        });
                    }

                    // Font list
                    const fontListEl = div({class: 'fontdlg-list', style: 'width:160px;'});
                    fonts.forEach(f => {
                        van.add(fontListEl, div({class: 'fontdlg-list-item' + (f === selFont ? ' selected' : ''), onclick: () => {
                            selFont = f;
                            fontInput.value = f;
                            selectListItem(fontListEl, f);
                            updatePreview();
                        }}, f));
                    });

                    // Style list
                    const styleListEl = div({class: 'fontdlg-list', style: 'width:100px;'});
                    styles.forEach((s, i) => {
                        van.add(styleListEl, div({class: 'fontdlg-list-item' + (i === getStyleIdx() ? ' selected' : ''), onclick: () => {
                            selBold = (i === 2 || i === 3);
                            selItalic = (i === 1 || i === 3);
                            styleInput.value = s;
                            selectListItem(styleListEl, s);
                            updatePreview();
                        }}, s));
                    });

                    // Size list
                    const sizeListEl = div({class: 'fontdlg-list', style: 'width:50px;'});
                    sizes.forEach(sz => {
                        van.add(sizeListEl, div({class: 'fontdlg-list-item' + (sz === selSize ? ' selected' : ''), onclick: () => {
                            selSize = sz;
                            sizeInput.value = String(sz);
                            selectListItem(sizeListEl, String(sz));
                            updatePreview();
                        }}, String(sz)));
                    });

                    // Handle text input changes
                    sizeInput.addEventListener('change', () => {
                        const v = parseInt(sizeInput.value);
                        if (v > 0 && v < 1000) { selSize = v; selectListItem(sizeListEl, String(v)); updatePreview(); }
                    });
                    fontInput.addEventListener('change', () => {
                        selFont = fontInput.value;
                        selectListItem(fontListEl, selFont);
                        updatePreview();
                    });

                    function onOK() {
                        if (ws && ws.readyState === WebSocket.OPEN) {
                            ws.send(JSON.stringify({ type: 'font_chosen', face: selFont, size: selSize, bold: selBold, italic: selItalic }));
                        }
                    }

                    updatePreview();

                    showDialog('Font',
                        div({class: 'fontdlg-body'},
                            div({class: 'fontdlg-col-row'},
                                div({class: 'fontdlg-col', style: 'flex:1;'},
                                    label('Font:'), fontInput, fontListEl),
                                div({class: 'fontdlg-col'},
                                    label('Font st' + 'yle:'), styleInput, styleListEl),
                                div({class: 'fontdlg-col'},
                                    label('Size:'), sizeInput, sizeListEl)),
                            div({style: 'display:flex; gap:8px; align-items:flex-start; margin-bottom:8px;'},
                                fieldset({style: 'border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow); margin:0; padding:4px 8px; flex:1;'},
                                    legend({style: 'font-size:11px; padding:0 4px;'}, 'Sample'),
                                    previewEl),
                                div({style: 'display:flex; flex-direction:column; gap:4px;'},
                                    button({class: 'win2k-button', style: 'min-width:73px;', onclick: () => onOK()}, 'OK'),
                                    button({class: 'win2k-button', style: 'min-width:73px;', onclick: () => closeDialog()}, 'Cancel'))))
                    );
                    dialogOverlay.style.width = '440px';

                    // Scroll to initial selections
                    setTimeout(() => {
                        selectListItem(fontListEl, selFont);
                        selectListItem(styleListEl, styles[getStyleIdx()]);
                        selectListItem(sizeListEl, String(selSize));
                    }, 50);

                } else if (msg.type === "show_print_dialog") {
                    // --- Print Dialog ---
                    let fromPage = msg.from || 1;
                    let toPage = msg.to || 1;
                    let copies = msg.copies || 1;
                    const minPage = msg.min || 1;
                    const maxPage = msg.max || 100;

                    const fromInput = input({type: 'text', class: 'win2k-edit', value: String(fromPage), style: 'width:50px; height:21px;'});
                    const toInput = input({type: 'text', class: 'win2k-edit', value: String(toPage), style: 'width:50px; height:21px;'});
                    const copiesInput = input({type: 'text', class: 'win2k-edit', value: String(copies), style: 'width:50px; height:21px;'});

                    function clampInt(v, lo, hi) {
                        const n = parseInt(v);
                        if (isNaN(n)) return lo;
                        return Math.max(lo, Math.min(n, hi));
                    }
                    fromInput.addEventListener('change', () => { fromPage = clampInt(fromInput.value, minPage, maxPage); fromInput.value = String(fromPage); });
                    toInput.addEventListener('change', () => { toPage = clampInt(toInput.value, minPage, maxPage); toInput.value = String(toPage); });
                    copiesInput.addEventListener('change', () => { copies = clampInt(copiesInput.value, 1, 999); copiesInput.value = String(copies); });

                    showDialog('Print',
                        div({class: 'fontdlg-body'},
                            div({class: 'fontdlg-col-row', style: 'align-items:flex-end; gap:10px; padding:8px 0;'},
                                div({class: 'fontdlg-col'}, label('From:'), fromInput),
                                div({class: 'fontdlg-col'}, label('To:'), toInput),
                                div({class: 'fontdlg-col'}, label('Copies:'), copiesInput)),
                            div({style: 'display:flex; justify-content:flex-end; gap:8px; margin-top:10px;'},
                                button({class: 'win2k-button', style: 'min-width:73px;', onclick: () => {
                                    if (ws && ws.readyState === WebSocket.OPEN) {
                                        ws.send(JSON.stringify({ type: 'print_chosen', from: fromPage, to: toPage, copies: copies }));
                                    }
                                }}, 'Print'),
                                button({class: 'win2k-button', style: 'min-width:73px;', onclick: () => closeDialog()}, 'Cancel')))
                    );
                    dialogOverlay.style.width = '360px';

                } else if (msg.type === "show_page_setup_dialog") {
                    // --- Page Setup Dialog ---
                    let left = msg.left || 1000;
                    let top = msg.top || 1000;
                    let right = msg.right || 1000;
                    let bottom = msg.bottom || 1000;
                    let paperW = msg.paperW || 8500;
                    let paperH = msg.paperH || 11000;
                    let orientation = msg.orientation || 0;
                    const units = msg.units || '0.001 in';

                    const leftEl = input({type: 'text', class: 'win2k-edit', value: String(left), style: 'width:70px; height:21px;'});
                    leftEl.addEventListener('change', () => { const n = parseInt(leftEl.value); if (!isNaN(n) && n >= 0) { left = n; } leftEl.value = String(left); });
                    const topEl = input({type: 'text', class: 'win2k-edit', value: String(top), style: 'width:70px; height:21px;'});
                    topEl.addEventListener('change', () => { const n = parseInt(topEl.value); if (!isNaN(n) && n >= 0) { top = n; } topEl.value = String(top); });
                    const rightEl = input({type: 'text', class: 'win2k-edit', value: String(right), style: 'width:70px; height:21px;'});
                    rightEl.addEventListener('change', () => { const n = parseInt(rightEl.value); if (!isNaN(n) && n >= 0) { right = n; } rightEl.value = String(right); });
                    const bottomEl = input({type: 'text', class: 'win2k-edit', value: String(bottom), style: 'width:70px; height:21px;'});
                    bottomEl.addEventListener('change', () => { const n = parseInt(bottomEl.value); if (!isNaN(n) && n >= 0) { bottom = n; } bottomEl.value = String(bottom); });

                    const landscapeChk = input({type: 'checkbox', id: 'ps-landscape', style: 'margin-right:4px;',
                        onchange: (e) => { orientation = e.target.checked ? 1 : 0; }});

                    showDialog('Page Setup',
                        div({class: 'fontdlg-body'},
                            div({style: 'font-size:11px; margin-bottom:6px;'}, 'Margins (' + units + '):'),
                            div({class: 'fontdlg-col-row', style: 'align-items:flex-end; gap:10px; margin-bottom:10px;'},
                                div({class: 'fontdlg-col'}, label('Left:'), leftEl),
                                div({class: 'fontdlg-col'}, label('Top:'), topEl),
                                div({class: 'fontdlg-col'}, label('Right:'), rightEl),
                                div({class: 'fontdlg-col'}, label('Bottom:'), bottomEl)),
                            div({style: 'font-size:11px; margin-bottom:6px;'}, 'Orientation:'),
                            div({style: 'display:flex; align-items:center; gap:6px; margin-bottom:10px;'},
                                landscapeChk, label('Landscape')),
                            div({style: 'display:flex; justify-content:flex-end; gap:8px;'},
                                button({class: 'win2k-button', style: 'min-width:73px;', onclick: () => {
                                    if (ws && ws.readyState === WebSocket.OPEN) {
                                        ws.send(JSON.stringify({ type: 'page_setup_chosen',
                                            left: left, top: top, right: right, bottom: bottom,
                                            paperW: paperW, paperH: paperH, orientation: orientation }));
                                    }
                                }}, 'OK'),
                                button({class: 'win2k-button', style: 'min-width:73px;', onclick: () => closeDialog()}, 'Cancel')))
                    );
                    dialogOverlay.style.width = '420px';

                } else if (msg.type === "open_find_dialog") {
                    // --- Find/Replace Dialog (modeless) ---
                    const isReplace = msg.mode === 'replace';
                    const dialogTitle = isReplace ? 'Replace' : 'Find';
                    let findText = msg.findText || '';
                    let replaceText = msg.replaceText || '';
                    let matchCase = false;
                    let searchDown = true;

                    const findInput = input({type: 'text', value: findText, style: 'width:100%;', id: 'find-input',
                        oninput: (e) => { findText = e.target.value; }});
                    const replaceInput = input({type: 'text', value: replaceText, style: 'width:100%;', id: 'replace-input',
                        oninput: (e) => { replaceText = e.target.value; }});
                    const matchCaseCheck = input({type: 'checkbox', id: 'find-match-case',
                        onchange: (e) => { matchCase = e.target.checked; }});

                    function sendFindAction(action) {
                        if (ws && ws.readyState === 1) {
                            ws.send(JSON.stringify({
                                type: 'find_action', action: action,
                                findText: findText, replaceText: replaceText,
                                matchCase: matchCase, searchDown: searchDown
                            }));
                        }
                    }

                    const replaceRow = isReplace ? div({style: 'display:flex; align-items:center; gap:8px; margin-bottom:8px;'},
                        label({style: 'min-width:80px;'}, 'Replace with:'), replaceInput) : null;

                    const replaceButtons = isReplace ? [
                        button({class: 'win2k-button', style: 'min-width:80px;', onclick: () => sendFindAction('replace')}, 'Replace'),
                        button({class: 'win2k-button', style: 'min-width:80px;', onclick: () => sendFindAction('replace_all')}, 'Replace All')
                    ] : [];

                    showDialog(dialogTitle,
                        div({style: 'display:flex; gap:12px;'},
                            div({style: 'flex:1;'},
                                div({style: 'display:flex; align-items:center; gap:8px; margin-bottom:8px;'},
                                    label({style: 'min-width:80px;'}, 'Find what:'), findInput),
                                replaceRow ? replaceRow : '',
                                div({style: 'display:flex; align-items:center; gap:16px; margin-top:4px;'},
                                    div({style: 'display:flex; align-items:center; gap:4px;'}, matchCaseCheck, label('Match case')),
                                    !isReplace ? fieldset({style: 'border:1px solid; border-color:var(--sys-shadow) var(--sys-hilight) var(--sys-hilight) var(--sys-shadow); margin:0; padding:4px 8px;'},
                                        legend({style: 'font-size:11px; padding:0 4px;'}, 'Direction'),
                                        div({style: 'display:flex; gap:12px;'},
                                            div({}, input({type: 'radio', name: 'find-dir', id: 'find-up',
                                                onchange: () => { searchDown = false; }}), label({for: 'find-up'}, 'Up')),
                                            div({}, input({type: 'radio', name: 'find-dir', id: 'find-down', checked: true,
                                                onchange: () => { searchDown = true; }}), label({for: 'find-down'}, 'Down'))
                                        )) : '')),
                            div({style: 'display:flex; flex-direction:column; gap:4px;'},
                                button({class: 'win2k-button', style: 'min-width:80px;', onclick: () => sendFindAction('find_next')}, 'Find Next'),
                                ...replaceButtons,
                                button({class: 'win2k-button', style: 'min-width:80px;', onclick: () => {
                                    sendFindAction('close');
                                    dialogOverlay.style.display = 'none';
                                }}, 'Cancel')))
                    );
                    dialogOverlay.style.width = isReplace ? '420px' : '380px';

                } else if (msg.type === "close_dialog") {
                    dialogOverlay.style.display = 'none';
                    document.getElementById('main-titlebar').classList.remove('inactive');

                } else if (msg.type === "set_edit_font") {
                    // Apply font to a child control by hwnd, fallback to #edit-control
                    let el = Array.from(document.querySelectorAll('[data-hwnd]')).find(e => e.dataset.hwnd == msg.hwnd);
                    if (!el) el = document.getElementById('edit-control');
                    if (el) {
                        el.style.fontFamily = "'" + msg.face + "', monospace";
                        el.style.fontSize = msg.size + 'pt';
                        el.style.fontWeight = msg.bold ? 'bold' : 'normal';
                        el.style.fontStyle = msg.italic ? 'italic' : 'normal';
                    }

                } else if (msg.type === "edit_setsel") {
                    // EM_SETSEL: set textarea selection
                    const el = document.getElementById('edit-control');
                    if (el) {
                        const start = msg.start < 0 ? 0 : msg.start;
                        const end = msg.end < 0 ? el.value.length : Math.min(msg.end, el.value.length);
                        el.setSelectionRange(start, end);
                        el.focus();
                    }

                } else if (msg.type === "edit_replacesel") {
                    // EM_REPLACESEL: replace selected text
                    const el = document.getElementById('edit-control');
                    if (el) {
                        const start = el.selectionStart;
                        const end = el.selectionEnd;
                        const before = el.value.substring(0, start);
                        const after = el.value.substring(end);
                        const newText = msg.text || '';
                        el.value = before + newText + after;
                        el.setSelectionRange(start + newText.length, start + newText.length);
                    }

                } else if (msg.type === "edit_undo") {
                    const el = document.getElementById('edit-control');
                    if (el) {
                        el.focus();
                        document.execCommand('undo');
                    }

                } else if (msg.type === "edit_scrollcaret") {
                    const el = document.getElementById('edit-control');
                    if (el) {
                        // Scroll textarea to make caret visible
                        const pos = el.selectionEnd;
                        el.blur();
                        el.focus();
                        el.setSelectionRange(pos, pos);
                    }

                } else if (msg.type === "enable_menu_item") {
                    // EnableMenuItem: add/remove .disabled class from menu items
                    document.querySelectorAll('[data-cmd-id]').forEach(item => {
                        if (item.dataset.cmdId != msg.id) return;
                        if (msg.enabled) {
                            item.classList.remove('disabled');
                        } else {
                            item.classList.add('disabled');
                        }
                    });
                    // Also update currentMenuData for persistence
                    if (currentMenuData) {
                        function updateMenuEnabled(items, id, enabled) {
                            for (const item of items) {
                                if (item.id === id) {
                                    if (enabled) {
                                        item.flags = (item.flags || 0) & ~0x0003;
                                    } else {
                                        item.flags = (item.flags || 0) | 0x0001;
                                    }
                                }
                                if (item.popup) updateMenuEnabled(item.popup, id, enabled);
                            }
                        }
                        updateMenuEnabled(currentMenuData, msg.id, msg.enabled);
                    }

                } else if (msg.type === "set_statusbar_parts") {
                    // Create status bar panes
                    const sb = document.querySelector('.win2k-statusbar');
                    if (sb) {
                        // Remove existing panes except grip
                        const grip = sb.querySelector('.win2k-statusbar-grip');
                        sb.innerHTML = '';
                        for (let i = 0; i < msg.count; i++) {
                            const pane = document.createElement('div');
                            pane.className = 'win2k-statusbar-pane';
                            pane.dataset.paneIdx = i;
                            if (i < msg.count - 1) pane.style.flex = 'none';
                            sb.appendChild(pane);
                        }
                        if (grip) sb.appendChild(grip);
                    }

                } else if (msg.type === "set_statusbar_text") {
                    // Update status bar pane text
                    const sb = document.querySelector('.win2k-statusbar');
                    if (sb) {
                        const pane = Array.from(sb.querySelectorAll('[data-pane-idx]')).find(e => e.dataset.paneIdx == msg.part);
                        if (pane) {
                            pane.textContent = msg.text;
                        } else {
                            // Fallback: if no panes exist, set entire statusbar text
                            const firstPane = sb.querySelector('.win2k-statusbar-pane') || sb;
                            firstPane.textContent = msg.text;
                        }
                    }

                } else if (msg.type === "set_clipboard") {
                    // Backend → browser clipboard
                    if (navigator.clipboard && navigator.clipboard.writeText) {
                        navigator.clipboard.writeText(msg.text).catch(() => {});
                    }

                } else if (msg.type === "set_edit_text") {
                    // Set textarea content from backend
                    const el = document.getElementById('edit-control');
                    if (el && msg.text !== undefined) {
                        el.value = msg.text;
                    }

                } else if (msg.type === "show_context_menu") {
                    // Render a context menu popup at (x, y) with items array
                    let ctxOverlay = document.getElementById('context-menu-overlay');
                    if (!ctxOverlay) {
                        ctxOverlay = document.createElement('div');
                        ctxOverlay.id = 'context-menu-overlay';
                        ctxOverlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:9999;';
                        document.body.appendChild(ctxOverlay);
                    }

                    const menuDiv = document.createElement('div');
                    menuDiv.className = 'popup-menu';
                    menuDiv.style.display = 'block';
                    menuDiv.style.position = 'absolute';
                    menuDiv.style.left = msg.x + 'px';
                    menuDiv.style.top = msg.y + 'px';
                    menuDiv.style.zIndex = '10000';

                    const items = msg.items || [];
                    items.forEach(item => {
                        if (item.separator) {
                            const sep = document.createElement('div');
                            sep.className = 'popup-separator';
                            menuDiv.appendChild(sep);
                        } else {
                            const mi = document.createElement('div');
                            mi.className = 'popup-item';
                            if (item.disabled) mi.classList.add('disabled');
                            if (item.checked) mi.classList.add('checked');
                            mi.textContent = item.text || '';
                            mi.addEventListener('click', () => {
                                ctxOverlay.remove();
                                if (ws.readyState === WebSocket.OPEN) {
                                    ws.send(JSON.stringify({ type: 'context_menu_select', id: item.id }));
                                }
                            });
                            menuDiv.appendChild(mi);
                        }
                    });

                    ctxOverlay.innerHTML = '';
                    ctxOverlay.appendChild(menuDiv);
                    ctxOverlay.addEventListener('click', (e) => {
                        if (e.target === ctxOverlay) {
                            ctxOverlay.remove();
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'context_menu_select', id: 0 }));
                            }
                        }
                    });

                } else if (msg.type === "set_title") {
                    document.title = msg.title;
                    document.getElementById('window-title').textContent = msg.title;
                    document.getElementById('taskbar-title').textContent = msg.title;

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

                    // Sync textarea content to backend on input (debounced)
                    // Remove previous listener to prevent duplicates
                    if (editEl._textSyncHandler) {
                        editEl.removeEventListener('input', editEl._textSyncHandler);
                    }
                    let textSyncTimer = null;
                    editEl._textSyncHandler = () => {
                        if (textSyncTimer) clearTimeout(textSyncTimer);
                        textSyncTimer = setTimeout(() => {
                            if (ws.readyState === WebSocket.OPEN) {
                                ws.send(JSON.stringify({ type: 'text_sync', text: editEl.value }));
                            }
                        }, 150);
                    };
                    editEl.addEventListener('input', editEl._textSyncHandler);

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
                } else if (msg.type === "desktop_icons") {
                    const desktop = document.getElementById('desktop-area');
                    // Replace the element to remove all old event listeners
                    const newDesktop = desktop.cloneNode(false);
                    desktop.parentNode.replaceChild(newDesktop, desktop);
                    desktopItems = msg.items || [];
                    const folderSvg = `<svg viewBox="0 0 32 32" width="32" height="32"><path d="M2 6h12l2 3h14v19H2z" fill="#FEC64F" stroke="#996515" stroke-width="0.5"/><path d="M2 9h28v16H2z" fill="#FEC64F"/></svg>`;
                    const docSvg = `<svg viewBox="0 0 32 32" width="32" height="32"><path d="M6 2h14l6 6v22H6z" fill="#fff" stroke="#888" stroke-width="0.8"/><path d="M20 2l6 6h-6z" fill="#ccc" stroke="#888" stroke-width="0.5"/><line x1="10" y1="14" x2="22" y2="14" stroke="#999" stroke-width="0.8"/><line x1="10" y1="17" x2="22" y2="17" stroke="#999" stroke-width="0.8"/><line x1="10" y1="20" x2="18" y2="20" stroke="#999" stroke-width="0.8"/></svg>`;
                    const exeSvg = `<svg viewBox="0 0 32 32" width="32" height="32"><rect x="4" y="2" width="24" height="28" rx="2" fill="#ddd" stroke="#666" stroke-width="0.8"/><rect x="7" y="5" width="18" height="12" fill="#000080"/><rect x="9" y="8" width="4" height="2" fill="#0f0"/><rect x="15" y="8" width="6" height="2" fill="#0ff"/><rect x="9" y="11" width="8" height="2" fill="#ff0"/><rect x="8" y="20" width="7" height="3" rx="1" fill="#c0c0c0" stroke="#888" stroke-width="0.5"/><rect x="17" y="20" width="7" height="3" rx="1" fill="#c0c0c0" stroke="#888" stroke-width="0.5"/><rect x="8" y="25" width="16" height="3" rx="1" fill="#c0c0c0" stroke="#888" stroke-width="0.5"/></svg>`;
                    const gbSvg = `<svg viewBox="0 0 32 32" width="32" height="32"><rect x="6" y="1" width="20" height="30" rx="3" fill="#c0b8a0" stroke="#888" stroke-width="0.8"/><rect x="9" y="4" width="14" height="12" rx="1" fill="#8bac0f" stroke="#666" stroke-width="0.5"/><circle cx="22" cy="21" r="3" fill="#a00050"/><circle cx="18" cy="24" r="2" fill="#a00050"/><rect x="9" y="21" width="5" height="1.5" rx="0.5" fill="#444"/><rect x="10.5" y="19.5" width="1.5" height="5" rx="0.5" fill="#444"/></svg>`;

                    let selectedIcon = null;
                    (msg.items || []).forEach(item => {
                        const iconEl = document.createElement('div');
                        iconEl.className = 'win2k-desktop-icon';
                        // Enter launches, so double-click is not the only route.
                        iconEl.tabIndex = 0;

                        const imgContainer = document.createElement('div');
                        if (item.icon) {
                            const img = document.createElement('img');
                            img.src = 'data:image/x-icon;base64,' + item.icon;
                            img.width = 32; img.height = 32;
                            img.style.imageRendering = 'pixelated';
                            imgContainer.appendChild(img);
                        } else if (item.is_dir) {
                            imgContainer.innerHTML = folderSvg;
                        } else {
                            const ext = (item.ext || '').toLowerCase();
                            if (ext === 'exe') imgContainer.innerHTML = exeSvg;
                            else if (ext === 'gb' || ext === 'gbc' || ext === 'mgb') imgContainer.innerHTML = gbSvg;
                            else imgContainer.innerHTML = docSvg;
                        }
                        iconEl.appendChild(imgContainer);

                        const lbl = document.createElement('div');
                        lbl.className = 'win2k-desktop-icon-label';
                        lbl.textContent = item.name;
                        iconEl.appendChild(lbl);

                        // Click to select
                        iconEl.addEventListener('click', (e) => {
                            e.stopPropagation();
                            closeStartMenu();
                            if (selectedIcon) selectedIcon.classList.remove('selected');
                            iconEl.classList.add('selected');
                            selectedIcon = iconEl;
                        });

                        // Enter activates the selected icon
                        iconEl.addEventListener('keydown', (e) => {
                            if (e.key !== 'Enter' && e.key !== ' ') return;
                            e.preventDefault();
                            e.stopPropagation();
                            launchDesktopItem(item.name);
                        });

                        // Double-click to launch
                        iconEl.addEventListener('dblclick', () => {
                            launchDesktopItem(item.name);
                        });

                        newDesktop.appendChild(iconEl);
                    });

                    // Click empty area to deselect
                    newDesktop.addEventListener('click', () => {
                        if (selectedIcon) { selectedIcon.classList.remove('selected'); selectedIcon = null; }
                    });
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
// Keystrokes aimed at a dialog control belong to that control, not the guest.
function isUiInputTarget(t) {
    return t instanceof Element && t.matches('input, textarea, select, [contenteditable="true"]');
}

window.addEventListener('keydown', (e) => {
    if (isUiInputTarget(e.target)) return;
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
    if (isUiInputTarget(e.target)) return;
    if (hasEditControl.val && document.activeElement === document.getElementById('edit-control')) return;
    if (e.altKey || e.code.startsWith('F') && !e.ctrlKey) e.preventDefault();
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'keyup', key: e.code }));
    }
});

// --- Mouse Input (forwarded to emulator) ---
function getCanvasCoords(e) {
    const rect = canvas.getBoundingClientRect();
    // Scale from CSS pixels to actual canvas (framebuffer) pixels
    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    return {
        x: Math.round((e.clientX - rect.left) * scaleX),
        y: Math.round((e.clientY - rect.top) * scaleY)
    };
}

canvas.addEventListener('mousedown', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN) {
        const c = getCanvasCoords(e);
        ws.send(JSON.stringify({ type: 'mousedown', x: c.x, y: c.y, button: e.button }));
    }
    e.preventDefault();
});

canvas.addEventListener('mouseup', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN) {
        const c = getCanvasCoords(e);
        ws.send(JSON.stringify({ type: 'mouseup', x: c.x, y: c.y, button: e.button }));
    }
    e.preventDefault();
});

canvas.addEventListener('mousemove', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN) {
        const c = getCanvasCoords(e);
        ws.send(JSON.stringify({ type: 'mousemove', x: c.x, y: c.y, button: e.button }));
    }
});

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

canvas.addEventListener('wheel', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN) {
        // Normalize the delta to Win32 wheel units (120 per notch).
        let delta = 0;
        if (e.deltaY !== 0) delta = e.deltaY > 0 ? -120 : 120;
        else if (e.deltaX !== 0) delta = e.deltaX > 0 ? 120 : -120;
        ws.send(JSON.stringify({ type: 'wheel', delta }));
    }
    e.preventDefault();
});

// --- Touch Input (mapped to mouse events for mobile support) ---
function getTouchCanvasCoords(touch) {
    const rect = canvas.getBoundingClientRect();
    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    return {
        x: Math.round((touch.clientX - rect.left) * scaleX),
        y: Math.round((touch.clientY - rect.top) * scaleY)
    };
}

canvas.addEventListener('touchstart', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN && e.touches.length > 0) {
        const c = getTouchCanvasCoords(e.touches[0]);
        ws.send(JSON.stringify({ type: 'mousedown', x: c.x, y: c.y, button: 0 }));
    }
    e.preventDefault();
}, { passive: false });

canvas.addEventListener('touchend', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN && e.changedTouches.length > 0) {
        const c = getTouchCanvasCoords(e.changedTouches[0]);
        ws.send(JSON.stringify({ type: 'mouseup', x: c.x, y: c.y, button: 0 }));
    }
    e.preventDefault();
}, { passive: false });

canvas.addEventListener('touchmove', (e) => {
    if (ws && ws.readyState === WebSocket.OPEN && e.touches.length > 0) {
        const c = getTouchCanvasCoords(e.touches[0]);
        ws.send(JSON.stringify({ type: 'mousemove', x: c.x, y: c.y, button: 0 }));
    }
    e.preventDefault();
}, { passive: false });

// --- Initialize ---
connect();
