/**
 * ludics Dashboard JavaScript
 *
 * This dashboard reads state from JSON files served by a simple HTTP server.
 * The ludics CLI generates these JSON files from the Markdown state files.
 *
 * To use:
 * 1. Run: ludics dashboard generate (creates dashboard/data/*.json)
 * 2. Serve: ludics dashboard serve
 * 3. Open: http://localhost:7678
 */

// Configuration
const CONFIG = {
    refreshInterval: 10000, // 10 seconds
    dataPath: 'data/',
    maxNotifications: 10,
    maxReadyTasks: 5
};

// State
let lastUpdate = null;

// Initialize dashboard
document.addEventListener('DOMContentLoaded', () => {
    console.log('ludics dashboard initializing...');
    fetchAllData();
    setInterval(fetchAllData, CONFIG.refreshInterval);
});

// Refresh immediately when tab becomes visible again
document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
        fetchAllData();
    }
});

// Fetch all dashboard data
async function fetchAllData() {
    try {
        await Promise.all([
            fetchSlots(),
            fetchReadyQueue(),
            fetchNotifications(),
            fetchMagStatus()
        ]);
        updateTimestamp();
        setConnectionStatus(true);
    } catch (error) {
        console.error('Failed to fetch data:', error);
        setConnectionStatus(false);
    }
}

// Fetch slot data
async function fetchSlots() {
    try {
        const response = await fetch(CONFIG.dataPath + 'slots.json');
        if (!response.ok) throw new Error('Failed to fetch slots');
        const slots = await response.json();
        renderSlots(slots);
    } catch (error) {
        // Use placeholder data if fetch fails
        console.warn('Using placeholder slot data');
        renderSlots(getPlaceholderSlots());
    }
}

// Render slot tiles
function renderSlots(slots) {
    for (let i = 1; i <= 6; i++) {
        const slot = slots.find(s => s.number === i) || { number: i, empty: true };
        const tile = document.getElementById(`slot-${i}`);
        if (!tile) continue;

        const statusDiv = tile.querySelector('.slot-status');
        const statusText = tile.querySelector('.status-text');
        const taskP = tile.querySelector('.task');
        const modeP = tile.querySelector('.mode');
        const phaseP = tile.querySelector('.phase');
        const linksDiv = tile.querySelector('.slot-links');

        if (slot.empty || !slot.process) {
            statusDiv.className = 'slot-status empty';
            statusText.textContent = 'Empty';
            taskP.textContent = '--';
            modeP.textContent = '--';
            phaseP.textContent = '--';
            linksDiv.innerHTML = '';
        } else {
            statusDiv.className = 'slot-status active';
            statusText.textContent = 'Active';
            taskP.textContent = slot.task || slot.process;
            modeP.textContent = slot.mode || '--';
            phaseP.textContent = slot.phase || '--';

            // Build terminal links
            let links = '';
            if (slot.terminals) {
                for (const [name, url] of Object.entries(slot.terminals)) {
                    links += `<a href="${url}" target="_blank">${name}</a>`;
                }
            }
            linksDiv.innerHTML = links;
        }
    }
}

// Fetch ready queue
async function fetchReadyQueue() {
    try {
        const response = await fetch(CONFIG.dataPath + 'ready.json');
        if (!response.ok) throw new Error('Failed to fetch ready queue');
        const tasks = await response.json();
        renderReadyQueue(tasks);
    } catch (error) {
        console.warn('Using placeholder ready queue');
        renderReadyQueue([]);
    }
}

// Render ready queue
function renderReadyQueue(tasks) {
    const list = document.getElementById('ready-list');
    if (!list) return;

    if (tasks.length === 0) {
        list.innerHTML = '<li class="empty">No ready tasks</li>';
        return;
    }

    const items = tasks.slice(0, CONFIG.maxReadyTasks).map(task => {
        const priority = task.priority || '-';
        const priorityClass = `priority-${priority}`;
        return `
            <li>
                <span class="priority ${priorityClass}">${priority}</span>
                <span class="task-title">${escapeHtml(task.title || task.id)}</span>
            </li>
        `;
    });

    list.innerHTML = items.join('');
}

// Fetch notifications
async function fetchNotifications() {
    try {
        const response = await fetch(CONFIG.dataPath + 'notifications.json');
        if (!response.ok) throw new Error('Failed to fetch notifications');
        const notifications = await response.json();
        renderNotifications(notifications);
    } catch (error) {
        console.warn('Using placeholder notifications');
        renderNotifications([]);
    }
}

// Render notifications
function renderNotifications(notifications) {
    const list = document.getElementById('notifications-list');
    if (!list) return;

    if (notifications.length === 0) {
        list.innerHTML = '<li class="empty">No recent notifications</li>';
        return;
    }

    const items = notifications.slice(0, CONFIG.maxNotifications).map(notif => {
        const time = formatTime(notif.timestamp);
        return `
            <li>
                <span class="notif-time">${time}</span>
                <span class="notif-msg">${escapeHtml(notif.message)}</span>
            </li>
        `;
    });

    list.innerHTML = items.join('');
}

// Fetch Mag status
async function fetchMagStatus() {
    try {
        const response = await fetch(CONFIG.dataPath + 'mag.json');
        if (!response.ok) throw new Error('Failed to fetch mag status');
        const mag = await response.json();
        renderMagStatus(mag);
    } catch (error) {
        console.warn('Using placeholder mag status');
        renderMagStatus({ status: 'unknown', lastActivity: null });
    }
}

// Render Mag status
function renderMagStatus(mag) {
    const statusSpan = document.getElementById('mag-status');
    const activitySpan = document.getElementById('mag-activity');
    const terminalLink = document.getElementById('mag-terminal');

    if (statusSpan) {
        statusSpan.textContent = mag.status || 'Unknown';
        if (mag.status === 'running') {
            statusSpan.style.color = 'var(--success)';
        } else {
            statusSpan.style.color = 'var(--text-secondary)';
        }
    }

    if (activitySpan) {
        activitySpan.textContent = mag.lastActivity
            ? formatTime(mag.lastActivity)
            : '--';
    }

    if (terminalLink && mag.terminal) {
        terminalLink.href = mag.terminal;
        terminalLink.style.display = 'inline';
    }
}

// Update last update timestamp
function updateTimestamp() {
    lastUpdate = new Date();
    const el = document.getElementById('last-update');
    if (el) {
        el.textContent = `Last update: ${formatTime(lastUpdate.toISOString())}`;
    }
}

// Set connection status indicator
function setConnectionStatus(connected) {
    const el = document.getElementById('connection-status');
    if (el) {
        el.className = connected ? 'connected' : 'disconnected';
        el.textContent = connected ? 'Connected' : 'Disconnected';
    }
}

// Run CLI command (opens in new tab with instructions)
function runCommand(cmd) {
    alert(`Run in terminal:\n\nludics ${cmd}`);
}

// Utility: Format timestamp
function formatTime(isoString) {
    if (!isoString) return '--';
    try {
        const date = new Date(isoString);
        const now = new Date();
        const diff = now - date;

        if (diff < 60000) return 'Just now';
        if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
        if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;

        return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], {
            hour: '2-digit',
            minute: '2-digit'
        });
    } catch {
        return isoString;
    }
}

// Utility: Escape HTML
function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

// Placeholder data for development/demo
function getPlaceholderSlots() {
    return [
        { number: 1, empty: true },
        { number: 2, empty: true },
        { number: 3, empty: true },
        { number: 4, empty: true },
        { number: 5, empty: true },
        { number: 6, empty: true }
    ];
}
