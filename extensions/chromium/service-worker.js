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

async function lookup(tabId) {
    // 1. Read selection + paragraph context from the content script.
    let payload;
    try {
        payload = await chrome.tabs.sendMessage(tabId, { type: "EXTRACT_SELECTION" });
    } catch (err) {
        return report(false, "无法读取此页选词。更新扩展后请刷新网页；浏览器内部页面不支持查词。");
    }
    if (!payload || payload.empty) {
        return report(false, "请先在网页正文中选中英文单词。");
    }

    // 2. Fetch token.
    const token = await getToken();
    if (!token) {
        return report(false, "尚未配对，请打开 Dictionary 扩展设置保存令牌。");
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
        return report(false, "无法连接 Dictionary，请启动 App 后重试。");
    }

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
    try {
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        if (!tab?.id) return report(false, "找不到当前网页。");
        return await lookup(tab.id);
    } catch {
        return report(false, "扩展查询失败，请重新加载扩展并刷新网页。");
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
