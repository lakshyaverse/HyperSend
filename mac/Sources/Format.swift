import Foundation

// Display formatting. Sizes and rates use decimal units (1 MB = 1,000,000
// bytes) because that is what Finder and every other transfer tool shows the
// user. The README reports the older MiB figures alongside these.

func formattedBytes(_ value: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(abs(value))
    var index = 0
    while size >= 1000, index < units.count - 1 {
        size /= 1000
        index += 1
    }
    let sign = value < 0 ? "-" : ""
    return index == 0 ? "\(sign)\(Int(size)) \(units[index])" : String(format: "%@%.1f %@", sign, size, units[index])
}

/// "53.4 MB/s" — decimal megabytes per second.
func formattedRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
    if bytesPerSecond >= 1_000_000_000 {
        return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
    }
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1000 {
        return String(format: "%.0f KB/s", bytesPerSecond / 1000)
    }
    return String(format: "%.0f B/s", bytesPerSecond)
}

/// "2.3 s" / "1 m 04 s"
func formattedDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    if seconds < 60 { return String(format: "%.1f s", seconds) }
    let minutes = Int(seconds) / 60
    let rest = Int(seconds) % 60
    return String(format: "%d m %02d s", minutes, rest)
}
