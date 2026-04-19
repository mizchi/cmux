import Foundation

/// v2 socket commands for the browserCDP panel family. Kept in a
/// dedicated file so TerminalController.swift doesn't grow further.
extension TerminalController {

    /// browser.cdp.launch { tab_id?, workspace?, window? } →
    ///   { surface_id, cdp_url?, status }
    ///
    /// Creates a new BrowserCDPPanel in the selected workspace's focused
    /// pane. cdp_url is null until Chromium finishes handshaking; clients
    /// poll browser.cdp.url if they need to wait.
    func v2BrowserCDPLaunch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create panel", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let paneId = ws.bonsplitController.focusedPaneId
            guard let paneId else {
                result = .err(code: "not_found", message: "No focused pane in workspace", data: nil)
                return
            }
            guard let panel = ws.newBrowserCDPSurface(inPane: paneId, focus: false) else {
                result = .err(code: "internal_error", message: "newBrowserCDPSurface returned nil", data: nil)
                return
            }

            var payload: [String: Any] = [
                "surface_id": panel.id.uuidString,
                "status": v2BrowserCDPStatus(for: panel),
            ]
            if let url = panel.endpoint?.webSocketURL.absoluteString {
                payload["cdp_url"] = url
            }
            result = .ok(payload)
        }
        return result
    }

    /// browser.cdp.url { surface_id } → { surface_id, cdp_url?, status }
    ///
    /// Returns the current CDP WebSocket URL for a BrowserCDPPanel.
    /// cdp_url is null while Chromium is still launching or after it has
    /// exited; callers poll if they need to wait for readiness.
    func v2BrowserCDPURL(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing 'surface_id'", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "Panel not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let panel = v2FindBrowserCDPPanel(tabManager: tabManager, panelId: surfaceId) else {
                return
            }
            var payload: [String: Any] = [
                "surface_id": panel.id.uuidString,
                "status": v2BrowserCDPStatus(for: panel),
            ]
            if let url = panel.endpoint?.webSocketURL.absoluteString {
                payload["cdp_url"] = url
            }
            result = .ok(payload)
        }
        return result
    }

    /// browser.cdp.list {} → { surfaces: [{ surface_id, workspace_id, cdp_url?, status }] }
    func v2BrowserCDPList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var surfaces: [[String: Any]] = []
        v2MainSync {
            for workspace in tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let cdp = panel as? BrowserCDPPanel else { continue }
                    var entry: [String: Any] = [
                        "surface_id": cdp.id.uuidString,
                        "workspace_id": workspace.id.uuidString,
                        "status": v2BrowserCDPStatus(for: cdp),
                    ]
                    if let url = cdp.endpoint?.webSocketURL.absoluteString {
                        entry["cdp_url"] = url
                    }
                    surfaces.append(entry)
                }
            }
        }
        return .ok(["surfaces": surfaces])
    }

    /// browser.cdp.close { surface_id } → { ok: true }
    func v2BrowserCDPClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing 'surface_id'", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "Panel not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let workspace = v2FindBrowserCDPWorkspace(tabManager: tabManager, panelId: surfaceId) else {
                return
            }
            _ = workspace.closePanel(surfaceId)
            result = .ok(["ok": true, "surface_id": surfaceId.uuidString])
        }
        return result
    }

    // MARK: - Helpers

    fileprivate func v2BrowserCDPStatus(for panel: BrowserCDPPanel) -> String {
        if panel.isChromiumExited { return "exited" }
        if panel.endpoint != nil { return "connected" }
        return "launching"
    }

    fileprivate func v2FindBrowserCDPPanel(tabManager: TabManager, panelId: UUID) -> BrowserCDPPanel? {
        for workspace in tabManager.tabs {
            if let panel = workspace.browserCDPPanel(for: panelId) {
                return panel
            }
        }
        return nil
    }

    fileprivate func v2FindBrowserCDPWorkspace(tabManager: TabManager, panelId: UUID) -> Workspace? {
        for workspace in tabManager.tabs {
            if workspace.browserCDPPanel(for: panelId) != nil {
                return workspace
            }
        }
        return nil
    }
}
