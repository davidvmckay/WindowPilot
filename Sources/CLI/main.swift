import Foundation
import ImageIO
import WindowPilotCore

// MARK: - CLI Entry Point

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"

let enumerator = WindowEnumerator()
let focuser = WindowFocuser()
let capture = WindowCapture()

switch command {
case "list", "ls":
    cmdList()
case "switch", "sw":
    let query = args.dropFirst(2).joined(separator: " ")
    guard !query.isEmpty else {
        printError("Usage: windowpilot-cli switch <query>")
        exit(1)
    }
    cmdSwitch(query: query)
case "focus":
    guard args.count > 2 else {
        printError("Usage: windowpilot-cli focus --id <windowID>")
        exit(1)
    }
    if args[2] == "--id", args.count > 3, let wid = UInt32(args[3]) {
        cmdFocusByID(windowID: wid)
    } else if let wid = UInt32(args[2]) {
        cmdFocusByID(windowID: wid)
    } else {
        printError("Usage: windowpilot-cli focus --id <windowID>")
        exit(1)
    }
case "search":
    let query = args.dropFirst(2).joined(separator: " ")
    guard !query.isEmpty else {
        printError("Usage: windowpilot-cli search <query>")
        exit(1)
    }
    cmdSearch(query: query)
case "capture":
    guard args.count > 2, let wid = UInt32(args[2]) else {
        printError("Usage: windowpilot-cli capture <windowID> [output.png]")
        exit(1)
    }
    let output = args.count > 3 ? args[3] : "window-\(wid).png"
    cmdCapture(windowID: wid, outputPath: output)
case "help", "--help", "-h":
    printHelp()
case "version", "--version", "-v":
    print("windowpilot-cli 1.0.0")
default:
    // If not a recognized command, treat as a switch query
    let query = args.dropFirst(1).joined(separator: " ")
    cmdSwitch(query: query)
}

// MARK: - Commands

func cmdList() {
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let apps = enumerator.enumerate(excludingPID: ownPID)

    if apps.isEmpty {
        print("No windows found.")
        return
    }

    for app in apps {
        print("\(app.name) (pid \(app.id))")
        for window in app.windows {
            let state: String
            switch window.state {
            case .normal: state = ""
            case .fullScreen: state = " [fullscreen]"
            case .minimized: state = " [minimized]"
            }
            let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
            print("  [\(window.id)] \(window.title)\(state)  \(size)")
        }
    }
}

func cmdSearch(query: String) {
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let apps = enumerator.enumerate(excludingPID: ownPID)
    let filtered = SearchFilter.filter(apps, query: query)

    if filtered.isEmpty {
        print("No windows matching \"\(query)\"")
        exit(1)
    }

    // Output as JSON for agent consumption
    var results: [[String: Any]] = []
    for app in filtered {
        for window in app.windows {
            results.append([
                "id": window.id,
                "pid": window.ownerPID,
                "app": app.name,
                "title": window.title,
                "state": "\(window.state)",
                "width": Int(window.bounds.width),
                "height": Int(window.bounds.height),
            ])
        }
    }

    // Print JSON
    if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

func cmdSwitch(query: String) {
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let apps = enumerator.enumerate(excludingPID: ownPID)
    let filtered = SearchFilter.filter(apps, query: query)

    guard let firstApp = filtered.first, let firstWindow = firstApp.windows.first else {
        printError("No window matching \"\(query)\"")
        exit(1)
    }

    print("Switching to: \(firstApp.name) — \(firstWindow.title) [id:\(firstWindow.id)]")

    let success = focuser.focus(
        pid: firstWindow.ownerPID,
        windowID: firstWindow.id,
        windowTitle: firstWindow.title,
        state: firstWindow.state
    )

    if !success {
        printError("Failed to focus window. Check Accessibility permission.")
        exit(1)
    }
}

func cmdFocusByID(windowID: UInt32) {
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let apps = enumerator.enumerate(excludingPID: ownPID)

    for app in apps {
        for window in app.windows where window.id == windowID {
            print("Focusing: \(app.name) — \(window.title) [id:\(window.id)]")
            let success = focuser.focus(
                pid: window.ownerPID,
                windowID: window.id,
                windowTitle: window.title,
                state: window.state
            )
            if !success {
                printError("Failed to focus window.")
                exit(1)
            }
            return
        }
    }

    printError("No window with ID \(windowID)")
    exit(1)
}

func cmdCapture(windowID: UInt32, outputPath: String) {
    guard let image = capture.capture(windowID: windowID) else {
        printError("Failed to capture window \(windowID). Check Screen Recording permission.")
        exit(1)
    }

    let url = URL(fileURLWithPath: outputPath)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        printError("Failed to create image file at \(outputPath)")
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        printError("Failed to write image")
        exit(1)
    }
    print("Saved to \(outputPath)")
}

// MARK: - Helpers

func printError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func printHelp() {
    print("""
    windowpilot-cli — Command-line window navigator for macOS

    USAGE:
        windowpilot-cli <command> [arguments]
        windowpilot-cli <query>           # shorthand for 'switch <query>'

    COMMANDS:
        list, ls                          List all windows
        switch, sw <query>                Fuzzy search and switch to first match
        search <query>                    Search windows, output JSON
        focus --id <windowID>             Focus a window by its ID
        capture <windowID> [output.png]   Capture window screenshot to file
        help                              Show this help
        version                           Show version

    EXAMPLES:
        windowpilot-cli list
        windowpilot-cli switch "chrome"
        windowpilot-cli sw terminal
        windowpilot-cli "safari"          # shorthand for switch
        windowpilot-cli search "code"     # JSON output for agents
        windowpilot-cli focus --id 61
        windowpilot-cli capture 61 screenshot.png

    NOTES:
        Requires Accessibility permission (System Settings > Privacy > Accessibility).
        Screen Recording permission needed for 'capture' command.
    """)
}
