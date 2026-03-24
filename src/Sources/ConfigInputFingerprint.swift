import Foundation

enum ConfigInputFingerprint {
    static func relevantFileURLs(
        in directoryURL: URL,
        userConfigFilename: String = "config.yaml",
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []

        let userConfigURL = directoryURL.appendingPathComponent(userConfigFilename)
        if fileManager.fileExists(atPath: userConfigURL.path) {
            urls.append(userConfigURL)
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return urls
        }

        let credentialFiles = files.filter { file in
            let name = file.lastPathComponent
            guard file.pathExtension == "json" else {
                return false
            }
            return name.hasPrefix("zai-") || name.hasPrefix("openai-compat-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        urls.append(contentsOf: credentialFiles)
        return urls
    }

    static func compute(
        in directoryURL: URL,
        userConfigFilename: String = "config.yaml",
        fileManager: FileManager = .default
    ) -> String {
        let urls = relevantFileURLs(
            in: directoryURL,
            userConfigFilename: userConfigFilename,
            fileManager: fileManager
        )

        guard !urls.isEmpty else {
            return ""
        }

        var parts: [String] = []
        parts.reserveCapacity(urls.count * 2)

        for url in urls {
            parts.append(url.lastPathComponent)
            if let data = try? Data(contentsOf: url) {
                parts.append(data.base64EncodedString())
            } else {
                parts.append("<unreadable>")
            }
        }

        return parts.joined(separator: "\n---\n")
    }
}
