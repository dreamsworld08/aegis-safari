import AppKit
import SafariServices
import Security
import os.log

/// Native bridge for the Aegis web extension.
/// Stores provider API keys in the macOS Keychain instead of browser storage.
/// Messages: {action: "get"|"set"|"delete", key: String, value?: String}
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let service = "dev.aegis.safari.apikeys"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let action = message["action"] as? String ?? ""
        let key = message["key"] as? String ?? ""

        var reply: [String: Any] = ["ok": false]
        if action == "launchUpdater" {
            reply = ["ok": launchContainingAppForUpdate()]
        } else if !key.isEmpty, key.count <= 128 {
            switch action {
            case "get":
                reply = ["ok": true, "value": read(key) ?? ""]
            case "set":
                if let value = message["value"] as? String, value.utf8.count <= 8192 {
                    reply = ["ok": write(key, value)]
                }
            case "delete":
                reply = ["ok": delete(key)]
            default:
                break
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Opens Aegis.app (which contains this extension) and asks it to install the latest update.
    private func launchContainingAppForUpdate() -> Bool {
        // .../Aegis.app/Contents/PlugIns/Aegis Extension.appex -> .../Aegis.app
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return false }
        if #available(macOS 10.15, *) {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--install-update"]
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            return true
        }
        return NSWorkspace.shared.open(appURL)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private func read(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ key: String, _ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound {
            os_log(.error, "Aegis keychain update failed: %d", status)
            return false
        }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func delete(_ key: String) -> Bool {
        let s = SecItemDelete(baseQuery(key) as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
