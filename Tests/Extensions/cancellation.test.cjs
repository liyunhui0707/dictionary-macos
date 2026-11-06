const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');

test('Chromium accepts 204 without notification or body parsing', async () => {
    const notifications = [];
    const context = vm.createContext({
        navigator: { userAgent: 'Chrome/' }, console,
        chrome: {
            tabs: { sendMessage: async () => ({ target: 'bank', context: 'river bank' }) },
            storage: { local: { get: async () => ({ token: 'test-token' }) } },
            notifications: { create: async (value) => notifications.push(value) },
            commands: { onCommand: { addListener() {} } }
        },
        fetch: async () => ({ status: 204, ok: true,
            json() { throw Error('204 has no JSON'); }, text() { throw Error('204 has no body'); } })
    });
    vm.runInContext(fs.readFileSync(path.join(root, 'extensions/chromium/service-worker.js'), 'utf8'), context);
    await vm.runInContext('lookup(1)', context);
    assert.deepEqual(notifications, []);
});

test('Obsidian accepts 204 without notification or body parsing', async () => {
    const notifications = [];
    const context = vm.createContext({
        console, module: { exports: {} }, navigator: { language: 'en' },
        require: () => ({
            Plugin: class {}, PluginSettingTab: class {}, Setting: class {},
            Notice: class { constructor(message) { notifications.push(message); } },
            requestUrl: async () => ({ status: 204, get json() { throw Error('204 has no JSON'); } })
        })
    });
    vm.runInContext(fs.readFileSync(path.join(root, 'extensions/obsidian/main.js'), 'utf8'), context);
    const plugin = new context.module.exports();
    plugin.settings = { tokenSecretId: 'test-token-id' };
    plugin.app = { secretStorage: { getSecret: () => 'test-token' } };
    plugin.credentialsBlocked = false;
    await plugin.lookup({ target: 'bank', context: 'river bank' });
    assert.deepEqual(notifications, []);
});
