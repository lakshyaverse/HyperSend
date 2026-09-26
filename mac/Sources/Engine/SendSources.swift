import Foundation

// Turning what the user hands us — files, folders, or a mix of both — into a
// flat, ordered send list.
//
// The wire protocol already carries a *relative* path per file and the receiver
// creates intermediate directories, so a folder keeps its own name and its whole
// subtree on the far side for free. Nothing extra is needed on the receiving
// end.

struct SendSource {
    let url: URL
    /// Where the receiver should write this file, relative to its destination.
    let relativePath: String
    let size: Int64
}

enum SourceError: Error, LocalizedError {
    case nothingToSend
    case tooManyFiles(Int)

    var errorDescription: String? {
        switch self {
        case .nothingToSend:
            return "nothing to send — that selection has no files in it"
        case let .tooManyFiles(count):
            return "too many files in one batch (\(count)) — send fewer at a time"
        }
    }
}

/// Metadata macOS scatters through folders and nobody means to send.
private let ignoredNames: Set<String> = [".DS_Store", ".localized"]

/// A batch is staged in memory as a list, so keep it to something sane.
let maxBatchFiles = 2000

/// Expands files and folders into a flat list, preserving folder structure.
///
/// Symlinks are skipped rather than followed, so a self-referential tree can
/// never turn into an infinite walk. Ordering is deterministic, which makes the
/// result easy to assert against in tests.
func collectSendSources(from urls: [URL]) throws -> [SendSource] {
    let fileManager = FileManager.default

    func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    var out: [SendSource] = []

    for url in urls {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

        if !isDirectory.boolValue {
            out.append(SendSource(url: url, relativePath: url.lastPathComponent, size: size(of: url)))
            continue
        }

        // The folder's own name becomes the top path segment, so the receiver
        // rebuilds the tree instead of dumping loose files into its root.
        let root = url
        let base = url.lastPathComponent
        var stack: [URL] = [url]

        while let current = stack.popLast() {
            let children = (try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [],
            )) ?? []

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if ignoredNames.contains(child.lastPathComponent) { continue }

                if values?.isDirectory == true {
                    stack.append(child)
                    continue
                }

                guard let relative = relativePath(of: child, under: root) else { continue }
                out.append(SendSource(
                    url: child,
                    relativePath: "\(base)/\(relative)",
                    size: size(of: child),
                ))
            }
        }
    }

    guard !out.isEmpty else { throw SourceError.nothingToSend }
    guard out.count <= maxBatchFiles else { throw SourceError.tooManyFiles(out.count) }

    return out.sorted { $0.relativePath < $1.relativePath }
}

/// `a/b/c.txt` relative to `a`, or nil if `url` is not actually under `root`.
private func relativePath(of url: URL, under root: URL) -> String? {
    let rootComponents = root.standardizedFileURL.pathComponents
    let fileComponents = url.standardizedFileURL.pathComponents
    guard fileComponents.count > rootComponents.count,
          Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    else { return nil }
    return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
}
