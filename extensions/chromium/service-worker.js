// Service worker — runs the lookup command:
//   1. Ask the active tab's content script for selection + paragraph context.
//   2. Pull the saved token from chrome.storage.
//   3. POST to the Mac app's localhost HTTP server.
//   4. Mac app shows the popup on success; we surface errors via notifications.

const SERVER_URL = "http://127.0.0.1:49152/v1/translate";

function detectBrowser() {
    const ua = navigator.userAgent || "";
    if (ua.includes("Edg/")) return "Edge";
    if (ua.includes("OPR/")) return "Opera";
    if (ua.includes("Vivaldi")) return "Vivaldi";
    if (ua.includes("Chrome/")) return "Chromium";
    return "Browser";
}

async function getToken() {
    const result = await chrome.storage.local.get("token");
    return (result.token || "").trim();
}

async function notify(message) {
    try {
        await chrome.notifications.create({
            type: "basic",
            iconUrl: "icons/48.png",
            title: "Dictionary",
            message
        });
    } catch (err) {
        console.error("[Dictionary] notification failed:", err);
    }
}

async function lookup(tabId) {
    // 1. Read selection + paragraph context from the content script.
    let payload;
    try {
        payload = await chrome.tabs.sendMessage(tabId, { type: "EXTRACT_SELECTION" });
    } catch (err) {
        await notify("Could not read selection on this page. Try reloading the tab.");
        return;
    }
    if (!payload || payload.empty) {
        await notify("No text selected. Highlight a word or phrase first.");
        return;
    }

    // 2. Fetch token.
    const token = await getToken();
    if (!token) {
        await notify("Extension token not set. Open extension options to paste it.");
        await chrome.runtime.openOptionsPage();
        return;
    }

    // 3. POST to the Mac app.
    let response;
    try {
        response = await fetch(SERVER_URL, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Authorization": `Bearer ${token}`
            },
            body: JSON.stringify({
                target: payload.target,
                context: payload.context,
                containingSentence: payload.containingSentence,
                sourceApp: detectBrowser(),
                capture: payload.capture
            })
        });
    } catch (err) {
        await notify("Dictionary app is not running. Launch it from Spotlight, then try again.");
        return;
    }

    if (response.status === 401) {
        await notify("Token rejected. Open extension options and paste a fresh token from the Mac app.");
        return;
    }
    if (response.status === 503) {
        const body = await response.json().catch(() => ({}));
        await notify(`Translation service error: ${body.error || "unknown"}`);
        return;
    }
    if (!response.ok) {
        const text = await response.text();
        await notify(`Server returned ${response.status}: ${text.slice(0, 200)}`);
        return;
    }
    // 200 — Mac app shows the popup. Nothing else to do.
}

chrome.commands.onCommand.addListener(async (command) => {
    if (command !== "lookup-selection") return;
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id) return;
    await lookup(tab.id);
});
