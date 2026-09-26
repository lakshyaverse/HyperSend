import Foundation

// Engine conformance tests. Compiled without AppKit against the engine sources
// only, so they run with nothing but the Command Line Tools:
//
//   ./test.sh
//
// They start a real receiver and a real sender in one process over loopback,
// which exercises the actual sockets, framing, chunk scheduler, resume logic
// and SHA-256 verification — no mocks.

private var failures = 0
private var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

func section(_ name: String) {
    print("\n\(name)")
}

let scratch = URL(fileURLWithPath: "/tmp/hypersend-tests")

/// Deterministic but non-trivial content, so a broken copy is detectable.
func makeFile(_ name: String, bytes: Int) -> URL {
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let url = scratch.appendingPathComponent(name)
    var data = Data(count: bytes)
    for index in 0 ..< bytes {
        data[index] = UInt8((index &* 31 &+ 7) % 251)
    }
    try! data.write(to: url)
    return url
}

func runEngineTests() -> Never {
    try? FileManager.default.removeItem(at: scratch)
    try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    let controlPort: UInt16 = 45110
    let dataPort: UInt16 = 45112

    let receiveDir = scratch.appendingPathComponent("inbox")
    try! FileManager.default.createDirectory(at: receiveDir, withIntermediateDirectories: true)

    let receiver = ReceiveEngine(
        destDir: receiveDir,
        controlPort: controlPort,
        dataPort: dataPort,
        hooks: ReceiveEngine.Hooks(
            accept: { _, _ in true },
            progress: { _, _, _ in },
            finished: { _ in },
            log: { _ in },
        ),
    )

    do {
        try receiver.start()
    } catch {
        print("could not start the test receiver: \(error.localizedDescription)")
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.4)

    // Two lanes into the same receiver: the primary takes the advertised data
    // port, the extra lane pins that same fixed port explicitly. Distinct socket
    // pools are exactly what the multipath scheduler is built around.
    let primaryLane = Lane(label: "wifi", host: "127.0.0.1", port: nil)
    let extraLane = Lane(label: "usb", host: "127.0.0.1", port: dataPort)

    // Bisect knobs so a failure can be narrowed without recompiling:
    //   HS_TEST_LANES=1 HS_TEST_SOCKETS=1 ./test.sh
    let laneCount = Int(ProcessInfo.processInfo.environment["HS_TEST_LANES"] ?? "2") ?? 2
    let socketCount = Int(ProcessInfo.processInfo.environment["HS_TEST_SOCKETS"] ?? "2") ?? 2
    print("  (lanes=\(laneCount), sockets per lane=\(socketCount))")

    func send(_ files: [URL], paths: [String]? = nil, sockets: Int? = nil) -> SendSummary? {
        do {
            return try SendEngine().send(
                files: files,
                paths: paths,
                primary: primaryLane,
                extraLanes: laneCount > 1 ? [extraLane] : [],
                controlPort: controlPort,
                socketsPerLane: sockets ?? socketCount,
            )
        } catch {
            print("    send failed: \(error.localizedDescription)")
            return nil
        }
    }

    // ── 1. Round trip ────────────────────────────────────────────────────────

    section("1. round trip over two lanes")
    let big = makeFile("round-trip.bin", bytes: 24 * 1024 * 1024)
    let bigHash = try! sha256File(big)
    let summary = send([big])

    check(summary != nil, "send completed without error")
    if let summary {
        check(summary.bytes == 24 * 1024 * 1024, "all bytes accounted for")
        check(summary.lanes.values.reduce(Int64(0)) { $0 + $1.bytes } == summary.bytes,
              "lane byte counts sum to the file size")
        check(summary.bytesPerSec > 0, "throughput measured (\(formattedRate(summary.bytesPerSec)))")
        print("    lanes: " + summary.lanes.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(formattedBytes($0.value.bytes))" }.joined(separator: " "))
    }

    let copiedBig = receiveDir.appendingPathComponent("round-trip.bin")
    check(FileManager.default.fileExists(atPath: copiedBig.path), "file landed in the receive directory")
    check((try? sha256File(copiedBig)) == bigHash, "received bytes hash-match the source")

    // ── 2. Identical re-send is a no-op ──────────────────────────────────────

    section("2. identical re-send is skipped, not re-transferred")
    let second = send([big])
    check(second != nil, "second send completed")
    check(second?.bytes == 0, "zero bytes moved (receiver already held the exact bytes)")

    // ── 3. Resume from a partial file ────────────────────────────────────────

    section("3. resume from a partial file")
    let partial = makeFile("resume.bin", bytes: 16 * 1024 * 1024)
    let partialHash = try! sha256File(partial)
    let partialTarget = receiveDir.appendingPathComponent("resume.bin")
    let fullBytes = try! Data(contentsOf: partial)
    try! fullBytes.prefix(6 * 1024 * 1024).write(to: partialTarget)
    let stagedSize = (try? FileManager.default.attributesOfItem(atPath: partialTarget.path)[.size] as? Int) ?? 0
    check(stagedSize == 6 * 1024 * 1024, "staged a 6 MB partial file")

    let resumed = send([partial])
    check(resumed != nil, "resumed send completed")
    check(resumed?.bytes == 10 * 1024 * 1024, "only the missing 10 MB were transmitted")
    check((try? sha256File(partialTarget)) == partialHash, "resumed file hash-matches the source")

    // ── 4. Zero-byte file ────────────────────────────────────────────────────

    section("4. zero-byte file")
    let empty = makeFile("empty.bin", bytes: 0)
    let emptySummary = send([empty])
    check(emptySummary != nil, "empty file accepted")
    let emptyTarget = receiveDir.appendingPathComponent("empty.bin")
    check(FileManager.default.fileExists(atPath: emptyTarget.path), "empty file exists on the receiving side")
    check((try? sha256File(emptyTarget)) == (try? sha256File(empty)), "empty file hash-matches")

    // ── 5. Path traversal ────────────────────────────────────────────────────

    // ── 5. Batch send ────────────────────────────────────────────────────────

    // Several files in ONE session: the sender opens its data sockets once and
    // reuses that pool for every file, so the receiver must keep the same
    // sockets and the same data listener alive from the first offer to the
    // last. This is the case a per-file teardown gets wrong.
    section("5. batch of several files over one session")
    let batchA = makeFile("batch-a.bin", bytes: 5 * 1024 * 1024)
    let batchB = makeFile("batch-b.bin", bytes: 128 * 1024)
    let batchC = makeFile("batch-c.bin", bytes: 3 * 1024 * 1024 + 7)
    let batchTotal: Int64 = 5 * 1024 * 1024 + 128 * 1024 + 3 * 1024 * 1024 + 7
    let batchSummary = send([batchA, batchB, batchC])
    check(batchSummary != nil, "batch send completed")
    check(batchSummary?.files == 3, "all three files reported done")
    check(batchSummary?.bytes == batchTotal, "batch moved exactly the sum of the files")
    for source in [batchA, batchB, batchC] {
        let landed = receiveDir.appendingPathComponent(source.lastPathComponent)
        check((try? sha256File(landed)) == (try? sha256File(source)),
              "\(source.lastPathComponent) landed and hash-matches")
    }
    let batchAgain = send([batchA, batchB, batchC])
    check(batchAgain?.bytes == 0, "re-sending the batch moves zero bytes")

    section("6. path safety")
    func rejects(_ path: String) -> Bool { (try? sanitizeRelativePath(path)) == nil }
    check(rejects("../evil.txt"), "rejects ../evil.txt")
    check(rejects("nested/../../evil.txt"), "rejects nested/../../evil.txt")
    check(rejects("/etc/passwd"), "rejects absolute paths")
    check(rejects("a//b.txt"), "rejects empty path segments")
    check(rejects("..\\windows\\evil"), "rejects Windows-style traversal")
    check(!rejects("photos/holiday.jpg"), "accepts nested relative paths")
    check((try? sanitizeRelativePath("a\\b\\c.txt")) == "a/b/c.txt", "normalises backslashes")

    // ── 7. Framing constants ─────────────────────────────────────────────────

    section("7. framing matches the reference implementation")
    let header = be32(UInt32(Proto.chunkHeaderBytes - 4 + 1000))
    check(header.count == 4, "length prefix is 4 bytes")
    check(header.be32(at: 0) == 1009, "chunk length field = 9 + payload (v2 framing)")
    check(Proto.chunkHeaderBytes == 13, "chunk header is 13 bytes on the wire")
    check(Proto.chunkSize == 2 * 1024 * 1024, "chunk size is 2 MiB")
    check(Proto.usbDataPort == 44012, "USB lane data port is the fixed 44012")

    // ── 8. Folder sends ──────────────────────────────────────────────────────

    section("8. a folder keeps its structure on the far side")
    let tree = scratch.appendingPathComponent("tree")
    try! FileManager.default.createDirectory(
        at: tree.appendingPathComponent("sub/deep"),
        withIntermediateDirectories: true,
    )
    _ = makeFile("tree/top.bin", bytes: 300 * 1024)
    _ = makeFile("tree/sub/nested.bin", bytes: 4 * 1024 * 1024)
    _ = makeFile("tree/sub/deep/deepest.bin", bytes: 64 * 1024)
    // macOS metadata that must never cross the wire.
    try! Data([0]).write(to: tree.appendingPathComponent(".DS_Store"))

    let collected = (try? collectSendSources(from: [tree])) ?? []
    check(collected.count == 3, "folder expanded to exactly its 3 real files (got \(collected.count))")
    check(
        collected.map(\.relativePath) == [
            "tree/sub/deep/deepest.bin",
            "tree/sub/nested.bin",
            "tree/top.bin",
        ],
        "relative paths preserve the tree, including the folder's own name",
    )
    check(!collected.contains { $0.relativePath.hasSuffix(".DS_Store") }, ".DS_Store is skipped")

    let folderSummary = send(collected.map(\.url), paths: collected.map(\.relativePath))
    check(folderSummary != nil, "folder send completed")
    for source in collected {
        let landed = receiveDir.appendingPathComponent(source.relativePath)
        check(
            (try? sha256File(landed)) == (try? sha256File(source.url)),
            "\(source.relativePath) landed at the same relative path",
        )
    }

    let folderAgain = send(collected.map(\.url), paths: collected.map(\.relativePath))
    check(folderAgain?.bytes == 0, "re-sending the folder moves zero bytes")

    // ── Result ───────────────────────────────────────────────────────────────

    receiver.stop()
    print("\n\(checks - failures)/\(checks) checks passed")
    if failures == 0 {
        print("ALL TESTS PASSED")
        exit(0)
    } else {
        print("\(failures) FAILED")
        exit(1)
    }
}
