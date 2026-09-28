import Foundation

/// Where the pet listens, and the rules that keep it a purely local channel.
///
/// A Unix domain socket rather than a TCP port on loopback: it cannot be reached
/// from another machine even by accident, it is subject to filesystem
/// permissions, and its existence doubles as the "is the pet running?" check the
/// hook needs.
public enum HooklingSocket {
    /// Overrides the socket path. Used by the tests and by anyone running two
    /// pets side by side.
    public static let environmentVariable = "HOOKLING_SOCKET"

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the terminator.
    public static let maximumPathLength = 103

    public static let directoryName = "Hookling"
    public static let fileName = "hookling.sock"

    /// `~/Library/Application Support/Hookling/hookling.sock`
    ///
    /// About 62 characters for a typical home directory, comfortably inside the
    /// `sockaddr_un` limit.
    public static func defaultPath(homeDirectory: String) -> String {
        "\(homeDirectory)/Library/Application Support/\(directoryName)/\(fileName)"
    }

    public static func resolvedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let override = environment[environmentVariable], !override.isEmpty {
            return override
        }
        return defaultPath(homeDirectory: homeDirectory)
    }

    public static func isUsable(path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= maximumPathLength
    }
}
