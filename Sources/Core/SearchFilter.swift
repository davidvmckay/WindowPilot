/// Filters an app/window tree by a search query string.
public struct SearchFilter {

    /// Filter app tree by query string. Returns a filtered copy.
    ///
    /// - Empty query: returns all apps unchanged
    /// - Query matches app name: returns that app with ALL its windows
    /// - Query matches window title only: returns parent app with only matching windows
    /// - Case-insensitive substring matching; leading/trailing whitespace is trimmed
    public static func filter(_ apps: [AppNode], query: String) -> [AppNode] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }

        let q = trimmed.lowercased()

        var result: [AppNode] = []

        for app in apps {
            let appNameLower = app.name.lowercased()

            // If query matches app name, return this app with all windows
            if appNameLower.contains(q) {
                result.append(app)
                continue
            }

            // Otherwise, filter to only windows whose title matches
            let matchingWindows = app.windows.filter { window in
                window.title.lowercased().contains(q)
            }

            if !matchingWindows.isEmpty {
                var filteredApp = app
                filteredApp.windows = matchingWindows
                result.append(filteredApp)
            }
        }

        return result
    }
}
