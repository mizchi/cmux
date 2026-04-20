import Foundation

/// v2 socket commands for the browserCDP panel family. Kept in a
/// dedicated file so `TerminalController.swift` doesn't grow further.
extension TerminalController {

    /// browser.cdp.launch { tab_id?, workspace?, window? }
    ///   → { surface_id, cdp_url?, status }
    func v2BrowserCDPLaunch(params: [String: Any]) -> V2CallResult {
        runOnTabManager(params: params) { tabManager in
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            self.v2MaybeFocusWindow(for: tabManager)
            self.v2MaybeSelectWorkspace(tabManager, workspace: ws)
            guard let paneId = ws.bonsplitController.focusedPaneId else {
                return .err(code: "not_found", message: "No focused pane in workspace", data: nil)
            }
            guard let panel = ws.newBrowserCDPSurface(inPane: paneId, focus: false) else {
                return .err(code: "internal_error",
                            message: "newBrowserCDPSurface returned nil", data: nil)
            }
            return .ok(self.panelEnvelope(for: panel))
        }
    }

    /// browser.cdp.url { surface_id } → { surface_id, cdp_url?, status }
    func v2BrowserCDPURL(params: [String: Any]) -> V2CallResult {
        runWithSurfaceID(params: params) { tabManager, surfaceId in
            guard let panel = self.findBrowserCDPPanel(tabManager: tabManager, panelId: surfaceId) else {
                return .err(code: "not_found", message: "Panel not found",
                            data: ["surface_id": surfaceId.uuidString])
            }
            return .ok(self.panelEnvelope(for: panel))
        }
    }

    /// browser.cdp.list {}
    ///   → { surfaces: [{ surface_id, workspace_id, cdp_url?, status }] }
    func v2BrowserCDPList(params: [String: Any]) -> V2CallResult {
        runOnTabManager(params: params) { tabManager in
            let surfaces = tabManager.tabs.flatMap { workspace in
                workspace.panels.values.compactMap { panel -> [String: Any]? in
                    guard let cdp = panel as? BrowserCDPPanel else { return nil }
                    var entry = self.panelEnvelope(for: cdp)
                    entry["workspace_id"] = workspace.id.uuidString
                    return entry
                }
            }
            return .ok(["surfaces": surfaces])
        }
    }

    /// browser.cdp.close { surface_id } → { ok: true, surface_id }
    func v2BrowserCDPClose(params: [String: Any]) -> V2CallResult {
        runWithSurfaceID(params: params) { tabManager, surfaceId in
            guard let workspace = self.findBrowserCDPWorkspace(tabManager: tabManager, panelId: surfaceId) else {
                return .err(code: "not_found", message: "Panel not found",
                            data: ["surface_id": surfaceId.uuidString])
            }
            _ = workspace.closePanel(surfaceId)
            return .ok(["ok": true, "surface_id": surfaceId.uuidString])
        }
    }

    // MARK: - Private helpers

    /// Shared boilerplate for all browser.cdp.* handlers: resolve the
    /// tab manager, hop to main, run `body`, return its `V2CallResult`.
    private func runOnTabManager(
        params: [String: Any],
        body: @escaping (TabManager) -> V2CallResult
    ) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: "No result", data: nil)
        v2MainSync { result = body(tabManager) }
        return result
    }

    /// Like `runOnTabManager` but also pulls `surface_id` out of the
    /// params up front, so commands that need a UUID don't repeat the
    /// validation block.
    private func runWithSurfaceID(
        params: [String: Any],
        body: @escaping (TabManager, UUID) -> V2CallResult
    ) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing 'surface_id'", data: nil)
        }
        return runOnTabManager(params: params) { body($0, surfaceId) }
    }

    private func panelEnvelope(for panel: BrowserCDPPanel) -> [String: Any] {
        var entry: [String: Any] = [
            "surface_id": panel.id.uuidString,
            "status": panel.isChromiumExited ? "exited"
                    : panel.endpoint != nil ? "connected"
                    : "launching",
        ]
        if let url = panel.endpoint?.webSocketURL.absoluteString {
            entry["cdp_url"] = url
        }
        return entry
    }

    private func findBrowserCDPPanel(tabManager: TabManager, panelId: UUID) -> BrowserCDPPanel? {
        tabManager.tabs.lazy
            .compactMap { $0.browserCDPPanel(for: panelId) }
            .first
    }

    private func findBrowserCDPWorkspace(tabManager: TabManager, panelId: UUID) -> Workspace? {
        tabManager.tabs.first { $0.browserCDPPanel(for: panelId) != nil }
    }
}
