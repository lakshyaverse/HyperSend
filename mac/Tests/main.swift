// Test runner entry point. Swift only allows top-level code in a file called
// main.swift, so the test body lives in EngineTests.swift and is invoked here.

import Darwin

// Unbuffered so a crash mid-test still shows how far we got.
setbuf(stdout, nil)
setbuf(stderr, nil)

runEngineTests()
