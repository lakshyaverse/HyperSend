#!/usr/bin/env swift
// Reads the text out of a screenshot with the Vision framework.
//
//   xcrun swift tools/ocr-screen.swift /tmp/hypersend-screen.png [top|bottom]
//
// The optional second argument crops the capture: `top` is the upper half of
// the screen, `bottom` the lower — useful when one window dominates a region.

import AppKit
import Vision

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !path.isEmpty, let image = NSImage(contentsOfFile: path),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot read \(path)") }

// Crop before OCR: full-screen captures bury small UI text in noise.
var work = cg
if CommandLine.arguments.count > 2 {
    let half = cg.height / 2
    let rect = CommandLine.arguments[2] == "top"
        ? CGRect(x: 0, y: 0, width: cg.width, height: half)
        : CGRect(x: 0, y: half, width: cg.width, height: half)
    work = cg.cropping(to: rect) ?? cg
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.automaticallyDetectsLanguage = false

let handler = VNImageRequestHandler(cgImage: work, options: [:])
do {
    try handler.perform([request])
    for observation in request.results ?? [] {
        if let line = observation.topCandidates(1).first {
            print(line.string)
        }
    }
} catch {
    fatalError("ocr failed: \(error)")
}
