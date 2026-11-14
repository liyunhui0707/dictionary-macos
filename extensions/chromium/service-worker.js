// Service worker — runs the lookup command:
//   1. Ask the active tab's content script for selection + paragraph context.
//   2. Pull the saved token from chrome.storage.
//   3. POST to the Mac app's localhost HTTP server.
//   4. Mac app shows the popup on success; we surface errors via notifications.

const SERVER_URL = "http://127.0.0.1:49152/v1/translate";
let lookupGeneration = 0;
let pendingCapture = null;
const sourceChanged = () => ({ok:false,message:"查询已取消：来源已变化或已有新查询，请重新选词。"});
function invalidateCapture() {
    if (pendingCapture) { lookupGeneration++; pendingCapture = null; }
}

// Invalidate capture work waiting on browser/storage APIs. Never submit an older
// selection after a new command, tab switch, window switch or document reload.
chrome.tabs.onActivated?.addListener(invalidateCapture);
chrome.tabs.onUpdated?.addListener((id, change) => {
    if (pendingCapture && id === pendingCapture.tabId &&
        (change.status === 'loading' || change.url)) invalidateCapture();
});
chrome.windows?.onFocusChanged?.addListener(invalidateCapture);

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

async function report(ok, message) {
    try {
        if (chrome.action) {
            await chrome.action.setBadgeText({ text: ok ? "" : "!" });
            if (!ok) await chrome.action.setBadgeBackgroundColor({ color: "#9b302f" });
        }
    } catch { /* Feedback failures must not suppress the lookup outcome. */ }
    if (!ok) await notify(message);
    return { ok, message };
}

async function checkConnection() {
    const token = await getToken();
    if (!token) return { ok: false, message: "尚未配对。请从 Dictionary 菜单复制扩展令牌并在此保存。" };
    try {
        const response = await fetch("http://127.0.0.1:49152/v1/status", {
            headers: { Authorization: `Bearer ${token}` },
            signal: AbortSignal.timeout(3000), cache: "no-store"
        });
        if (response.status === 401) return { ok: false, message: "配对已失效，请重新从当前 Dictionary 复制令牌。" };
        if (response.status === 404) return { ok: false, message: "Dictionary 版本较旧，请更新 App 后再检查连接。" };
        if (response.status !== 200) return { ok: false, message: `连接检查失败（HTTP ${response.status}）。` };
        const body = await response.json();
        if (body.service !== "dictionary" || body.protocol !== 1) return { ok: false, message: "本机服务响应不兼容。" };
        return { ok: true, message: "已连接 Dictionary。连接检查不会调用模型。" };
    } catch {
        return { ok: false, message: "无法连接 Dictionary，请启动 App；若已运行，检查是否有另一版本占用端口。" };
    }
}

async function lookup(tabId, request = {generation:++lookupGeneration,tab:{id:tabId}}) {
    const current = () => request.generation === lookupGeneration;
    pendingCapture = {generation:request.generation,tabId};
    // 1. Read selection + paragraph context from the content script.
    let payload;
    try {
        payload = await chrome.tabs.sendMessage(tabId, { type: "EXTRACT_SELECTION" }, {frameId:0});
    } catch (err) {
        if (!current()) return sourceChanged();
        return report(false, "无法读取此页选词。更新扩展后请刷新网页；浏览器内部页面不支持查词。");
    }
    if (!current()) return sourceChanged();
    if (!payload || payload.empty) {
        pendingCapture = null;
        if (payload?.reason === 'frameUnavailable') {
            return report(false, "无法读取当前嵌入式阅读区。跨域或受限页面可在 Dictionary 中手动输入单词与语境。");
        }
        return report(false, "请先在网页正文中选中英文单词。");
    }

    // 2. Fetch token.
    const token = await getToken();
    if (!current()) return sourceChanged();
    if (!token) {
        pendingCapture = null;
        return report(false, "尚未配对，请打开 Dictionary 扩展设置保存令牌。");
    }

    const [active] = await chrome.tabs.query({active:true,currentWindow:true});
    if (!current() || active?.id !== tabId ||
        (request.tab.url !== undefined && active.url !== request.tab.url) ||
        (request.tab.windowId !== undefined && active.windowId !== request.tab.windowId)) return sourceChanged();

    // 3. POST to the Mac app. No asynchronous gap after the source check.
    // Dictionary opening its own popup can move window focus after submission;
    // that must not turn a completed lookup into a spurious cancellation.
    pendingCapture = null;
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
        if (!current()) return sourceChanged();
        return report(false, "无法连接 Dictionary，请启动 App 后重试。");
    }

    if (!current()) return sourceChanged();

    if (response.status === 401) {
        return report(false, "配对已失效，请从当前 Dictionary 重新复制令牌。");
    }
    if (response.status === 503) {
        return report(false, "翻译服务暂不可用，请在 Dictionary 中检查查词服务设置。");
    }
    if (!response.ok) {
        return report(false, `查询失败（HTTP ${response.status}）。`);
    }
    return report(true, response.status === 204 ? "查询已取消。" : "查询已完成，请查看 Dictionary 浮窗。");
}

async function lookupActiveTab() {
    const generation = ++lookupGeneration;
    pendingCapture = {generation,tabId:null};
    try {
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        if (generation !== lookupGeneration) return sourceChanged();
        if (!tab?.id) return report(false, "找不到当前网页。");
        return await lookup(tab.id, {generation,tab});
    } catch {
        if (generation !== lookupGeneration) return sourceChanged();
        return report(false, "扩展查询失败，请重新加载扩展并刷新网页。");
    } finally {
        if (pendingCapture?.generation === generation) pendingCapture = null;
    }
}

chrome.commands.onCommand.addListener((command) => {
    if (command === "lookup-selection") void lookupActiveTab();
});

chrome.runtime?.onMessage?.addListener((message, sender, reply) => {
    // Only extension-owned pages may initiate a lookup or inspect saved pairing.
    if (sender.id !== chrome.runtime.id ||
        sender.url !== chrome.runtime.getURL("options.html")) return;
    if (message?.type === "CHECK_CONNECTION") {
        checkConnection().then(reply, () => reply({ ok: false, message: "连接检查失败。" }));
        return true;
    }
    if (message?.type === "LOOKUP_ACTIVE_TAB") {
        lookupActiveTab().then(reply, () => reply({ ok: false, message: "查询失败。" }));
        return true;
    }
});
