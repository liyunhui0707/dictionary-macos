const SERVER_URL = "http://127.0.0.1:49152/v1/translate";

const tokenInput = document.getElementById("token");
const verifyButton = document.getElementById("verify");
const clearButton = document.getElementById("clear");
const statusDiv = document.getElementById("status");

function setStatus(text, ok) {
    statusDiv.textContent = text;
    statusDiv.className = ok ? "ok" : "err";
}

async function loadCurrentToken() {
    const result = await chrome.storage.local.get("token");
    if (result.token) {
        tokenInput.value = result.token;
    }
}

async function verifyAndSave() {
    const token = tokenInput.value.trim();
    if (!token) {
        setStatus("Paste a token first.", false);
        return;
    }
    setStatus("Verifying…", true);
    try {
        const response = await fetch(SERVER_URL, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Authorization": `Bearer ${token}`
            },
            // Use a deliberately tiny payload — any non-401 reply proves auth works.
            body: JSON.stringify({ target: "ping", context: "ping" })
        });
        if (response.status === 401) {
            setStatus("Token rejected. Re-copy the token from the Mac menu and paste again.", false);
            return;
        }
        // Anything non-401 means auth succeeded; persist the token.
        await chrome.storage.local.set({ token });
        setStatus(`Saved. (Server replied ${response.status} ${response.statusText}.)`, true);
    } catch (err) {
        setStatus("Could not reach Dictionary app at 127.0.0.1:49152. Is it running?", false);
    }
}

async function clearToken() {
    await chrome.storage.local.remove("token");
    tokenInput.value = "";
    setStatus("Token cleared.", true);
}

verifyButton.addEventListener("click", verifyAndSave);
clearButton.addEventListener("click", clearToken);
loadCurrentToken();
