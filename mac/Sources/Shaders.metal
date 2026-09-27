#include <metal_stdlib>
using namespace metal;

// A drop on water, for the whole window.
//
// SwiftUI calls this as a `distortionEffect`: for every displayed position we
// return the source position to sample from. The wave is a ring-shaped
// wavefront travelling outward from the impact point while decaying — exactly
// the physics of a drop hitting water. Sampling lies behind the crest, so the
// glass visibly *bends* whatever is rendered beneath it: the sky smears,
// panel rims bow in and out, text wobbles and settles.
//
// `position` arrives in SwiftUI user space (points, Y down); the origin and
// maxRadius arguments are passed in the same space from the view layer.

// One ripple stage: a travelling Gaussian-windowed sine ring.
//
//   radius : the wavefront's current distance from the impact point
//   width  : ring width; wider reads as deeper water
//   amp    : peak sampling displacement at the crest, in points
static float2 rippleStage(float2 position, float2 origin, float radius,
                          float width, float amp) {
    float d = distance(position, origin);
    float x = d - radius;
    // Gaussian window: displacement lives only on the ring, so the rest of
    // the window stays perfectly still while the wave passes through.
    float envelope = exp(-x * x / (2.0 * width * width));
    // The sine alternates between pulling samples from behind the crest
    // (content stretches) and ahead of it (content squeezes) — that
    // alternation is what reads as refraction rather than blur.
    float offset = sin(x / width * 2.4) * envelope * amp;
    // Guard the degenerate centre.
    float dd = max(d, 0.0001);
    return (position - origin) / dd * offset;
}

// SwiftUI distortion effect entry point: maps displayed position to source
// position. `time` is seconds since the drop; `origin` is the drop point in
// points; `maxRadius` is how far the wavefront travels before it dies.
//
// [[stitchable]] is what makes the function visible to SwiftUI's shader
// pipeline — without it the default library does not export it for effects.
[[stitchable]] float2 dropRefraction(float2 position,
                                     float time,
                                     float2 origin,
                                     float maxRadius) {
    // The wavefront races out and eases down: fast start, long tail.
    float radius = maxRadius * (1.0 - pow(1.0 - min(time / 1.5, 1.0), 3.0));
    // Global decay: the water calms as the energy spreads.
    float energy = exp(-time * 2.1) * (1.0 - smoothstep(0.0, 1.45, time));
    // Three rings layered at different speeds and widths: a fast narrow
    // front, the main body, and a slow wide swell. One ring reads as a
    // graphics trick; their interference reads as liquid. Displacements are
    // in points (the kernel runs in SwiftUI user space).
    float2 offset = float2(0.0);
    offset += rippleStage(position, origin, radius, 14.0, 18.0);
    offset += rippleStage(position, origin, radius * 0.62, 8.0, 10.0);
    offset += rippleStage(position, origin, radius * 1.45, 24.0, 7.0);
    return position + offset * energy;
}
