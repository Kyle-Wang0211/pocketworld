# Capture Glass Toggles Design

**Date:** 2026-07-19  
**Repository baseline:** `1626543232eff47d1bd3664dad065165e472e1d7`  
**Target:** PocketWorld iOS capture flow (`ar-capture-rs`)

## Goal

Add a compact RealityScan-style two-button glass capsule above the existing
capture controls. Both controls start enabled. The left control independently
shows or hides world-anchored photo cards; the right independently shows or
hides the red/yellow/green coverage cloud. The glass must refract the final AR
composition — camera feed, coverage points, and photo cards together — while
keeping GPU cost small enough for the existing 30 Hz capture preview.

## Accepted UX

- No black bottom sheet and no opaque gray strip. The camera continues behind
  both the capsule and the existing shutter row.
- One centered capsule, `176 × 52 pt`, with `20 pt` corners.
- Reuse the community glass language: `0x08FFFFFF` tint, nominal thickness 20,
  IOR 1.20, saturation 1.0, and the same visual proportions.
- A thin 1 px translucent white border, subtle inner highlight, and a restrained
  shadow may be used for legibility; they must not become an opaque background.
- Left icon: outlined photo. Right icon: nine-dot coverage grid.
- Enabled state: `0xFFFFC53D`. Disabled state: translucent white-gray.
- Each half has at least a 44 × 44 pt hit target, a toggled accessibility state,
  and a stable semantic label.
- The controls are visible whenever the current manual capture bar is visible.
  They disappear with the rest of the capture UI during final reconstruction.
- Icons are drawn sharply above the glass. No synthetic green/yellow “AR dots”
  are added to the glass foreground.

## Rendering Architecture

### Dart owns UI and state

Dart owns capsule layout, icons, semantics, toggle state, callbacks, and
layout reporting. A focused `CaptureOverlayControls` widget is independently
testable without starting an AR session or creating a UIKit platform view.

The capture page maintains:

```dart
bool _photoCardsVisible = true;
bool _coveragePointsVisible = true;
```

The page sends only state changes and glass geometry over the existing
`aether_arkit` method channel. It never sends per-frame shader updates.

### Native owns AR-layer visibility

Photo cards and the coverage cloud are SceneKit nodes inside the native
`ARSCNView`; Flutter cannot selectively hide those nodes. Native therefore
provides a small, state-only API:

```text
setPhotoCardsVisible { visible: Bool }
setFeaturePointsVisible { visible: Bool }       // existing API
setCaptureGlassRect { x, y, width, height }     // logical points in preview
setCaptureGlassEnabled { enabled: Bool }
```

Hiding photo cards sets their container nodes' `isHidden` flag. It never
deletes anchors, specs, textures, or state. Cards created while hidden inherit
the hidden state and immediately reappear when enabled.

The existing coverage renderer removes its point node while hidden. Re-enabling
therefore calls `setFeaturePointsVisible(true)` and then pushes the latest
packed Dart coverage cloud so the previous points return immediately.

### Native post-process owns true refraction

A single `SCNTechnique` post-process is installed on the existing `ARSCNView`.
Its input is the SceneKit `COLOR` result after the camera background, photo
cards, and coverage cloud are composed. A Metal fragment function analytically
evaluates one rounded rectangle, computes a small refracted displacement, and
samples the composed color once. The yellow icons remain Flutter content above
the native view and are not themselves distorted.

The first implementation deliberately uses:

- one full-composition post-process pass;
- one displaced color sample inside the glass;
- no chromatic aberration;
- `half` arithmetic where precision permits;
- analytic rounded-rectangle distance/normal, with no geometry texture;
- a static capsule shape and uniforms updated only after layout changes;
- a guard band covering maximum displacement and bilinear sampling;
- `colorStates.clear = false` so pixels outside the effect cannot be cleared.

The nominal community `blur: 4` is a visual target, not permission for a
full-screen blur. The first device spike uses the one-sample clear-glass path.
Only if it is visually too sharp may a compile-time five-sample light frosting
variant be measured. Multi-pass Gaussian, Kawase, Dual Kawase, temporal reuse,
and full-screen Flutter backdrop filters are out of scope for the first pass.

## Coordinate Contract

Dart reports the capsule's global logical-point rectangle after layout. Native
converts that rectangle into local `ARSCNView` coordinates. The
`SCNTechnique` pass `viewport` remains in UIKit view coordinates (logical
points, upper-left origin); it must not be multiplied by
`contentScaleFactor`. The six-physical-pixel guard band is converted to points
and rounded outward to physical-pixel boundaries before the viewport string is
built. Physical full-frame and glass measurements are passed separately as
shader uniforms and are used to derive normalized full-frame UVs.

Native must update correctly after safe-area changes, rotation, resize, and
2×/3× display scale. A partial-viewport quad must sample with full-frame UVs
derived from raster position and the physical render size; using its local 0…1
UV would squeeze the whole camera image into the capsule. The padded sample
rectangle is clamped to the source texture bounds.

Apple supports one technique pass that reads and writes the symbolic `COLOR`
target. This is not evidence that SceneKit performs the operation in-place or
avoids a hidden full-frame copy/resolve, and `clear = false` does not publicly
guarantee preservation of untouched pixels outside a partial viewport. Both
properties remain device-spike acceptance gates.

## State and Failure Behavior

- Both toggles reset to enabled for a fresh capture page/session.
- Starting capture synchronizes the current Dart visibility values instead of
  hard-coding coverage visibility to true.
- Toggle calls are best-effort display operations: a channel failure must not
  interrupt image capture, finalization, or navigation.
- Page disposal disables/removes the glass technique and restores native
  visibility defaults so another preview cannot inherit stale UI state.
- Repeated taps are idempotent; each control affects only its own layer.

## Device Spike and Acceptance Gates

The native path is accepted only after an iPhone 14 Pro device spike proves:

1. A background feature, one colored coverage point, and one photo card all
   bend inside the same capsule.
2. Pixels outside the capsule and guard band remain unchanged, with no black
   clear, stretch, seam, or edge leak.
3. The capsule remains aligned at 2×/3× scale and after resize/orientation.
4. Both toggles default on, operate independently, and restore hidden content;
   cards captured while hidden also restore.
5. VoiceOver exposes distinct labels and toggled states, with 44 pt targets.
6. Relative to an otherwise identical no-technique baseline, p95 GPU frame time
   increases by no more than 1.0 ms and no additional 30 Hz preview misses are
   introduced in a representative 60-second run.
7. GPU Frame Capture shows whether the technique forces a full-frame
   store/resolve/copy. A passthrough pass is measured separately so hidden
   bandwidth is not misattributed to shader samples.
8. Thermal state is recorded before and after repeated/interleaved baseline,
   passthrough, one-sample, and optional five-sample runs.

If `SCNTechnique` does not receive all three native layers, clears outside the
ROI, or its passthrough cost already exceeds the budget, this route stops. A
camera-only `ARFrame.capturedImage` crop is not an acceptable substitute because
it excludes photo cards and coverage points. The only valid fallback is a
separate project that renders the complete AR composition into an
IOSurface-backed `FlutterTexture`.

## Verification

Automated checks cover:

- active/inactive colors, icon count, semantics, hit targets, and independent
  callbacks for `CaptureOverlayControls`;
- layout rectangle reporting without repeated unchanged channel calls;
- method-channel payloads and the required coverage re-push order;
- pure native coordinate/configuration helpers where practical;
- Flutter analysis/tests and an iOS profile build with signing disabled.

Final acceptance additionally requires a signed device build, launch on the
connected iPhone, manual layer-toggle checks, and the GPU/device measurements
above. Simulator screenshots cannot approve true AR refraction.
