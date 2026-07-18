import Foundation

// MARK: - ShellQuoting

/// Safe embedding of untrusted paths into a privileged AppleScript
/// `do shell script` command.
///
/// The escaping here only protects the AppleScript string literal itself
/// (backslash and double-quote, per the AppleScript grammar). It is
/// deliberately NOT responsible for shell metacharacter safety — that is
/// the job of AppleScript's `quoted form of` applied to the resulting
/// string on the shell side. Never build a shell command by string
/// interpolation; always route untrusted values through
/// `quoted form of` in the script.
public enum ShellQuoting {

    /// Escapes `\` and `"` so `s` can be embedded inside a double-quoted
    /// AppleScript string literal (`"..."`). Backslashes are escaped first
    /// so a literal `\"` in the input does not get misread as an escaped
    /// quote after substitution.
    public static func appleScriptStringLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// True if `s` contains any ASCII control character (0x00–0x1F).
    /// Nothing sane lives at such a path — callers should refuse to build
    /// a script around it rather than attempt to escape it.
    public static func containsControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value <= 0x1F }
    }
}
