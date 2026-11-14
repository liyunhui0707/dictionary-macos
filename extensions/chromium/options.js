const STATUS_URL = "http://127.0.0.1:49152/v1/status";
const tokenInput = document.getElementById("token");
const statusDiv = document.getElementById("status");
function setStatus(text, ok) {
    statusDiv.textContent = text;
    statusDiv.className = ok ? "ok" : "err";
}
async function verifyAndSave() {
    const token = tokenInput.value.trim();
    if (!token) { setStatus("请先粘贴新的配对令牌。", false); return; }
    setStatus("正在验证…", true);
    try {
        const response = await fetch(STATUS_URL, {
            headers: { Authorization: `Bearer ${token}` },
            signal: AbortSignal.timeout(3000), cache: "no-store"
        });
        if (response.status !== 200) {
            setStatus(response.status === 401 ? "令牌不匹配，请从当前 Dictionary 重新复制。" :
                response.status === 404 ? "请更新 Dictionary App 后再配对。" : `验证失败（HTTP ${response.status}）。`, false);
            return;
        }
        const body = await response.json();
        if (body.service !== "dictionary" || body.protocol !== 1) {
            setStatus("本机服务响应不兼容，未保存令牌。", false); return;
        }
        await chrome.storage.local.set({ token });
        tokenInput.value = "";
        setStatus("配对已保存。验证不会调用模型。", true);
    } catch { setStatus("无法连接 Dictionary，请确认 App 已启动。", false); }
}
async function checkConnection() {
    setStatus("正在检查连接…", true);
    try {
        const result = await chrome.runtime.sendMessage({ type: "CHECK_CONNECTION" });
        setStatus(result.message, result.ok);
    } catch { setStatus("扩展未响应，请重新加载扩展。", false); }
}
document.getElementById("verify").addEventListener("click", verifyAndSave);
document.getElementById("check").addEventListener("click", checkConnection);
document.getElementById("lookup").addEventListener("click", async () => {
    setStatus("正在查询当前网页选词…", true);
    try {
        const result = await chrome.runtime.sendMessage({ type: "LOOKUP_ACTIVE_TAB" });
        setStatus(result.message, result.ok);
    } catch { setStatus("扩展未响应，请重新加载扩展。", false); }
});
document.getElementById("clear").addEventListener("click", async () => {
    await chrome.storage.local.remove("token");
    tokenInput.value = "";
    setStatus("已清除配对。", true);
});
async function showShortcut() {
    try {
        const commands = await chrome.commands.getAll();
        const shortcut = commands.find(c => c.name === "lookup-selection")?.shortcut;
        document.getElementById("shortcut").textContent = shortcut ? `当前快捷键：${shortcut}` :
            "尚未绑定快捷键，请在浏览器扩展的键盘快捷方式页面设置。";
    } catch { document.getElementById("shortcut").textContent = "请在浏览器扩展页面检查快捷键。"; }
}
void showShortcut();
void checkConnection();
