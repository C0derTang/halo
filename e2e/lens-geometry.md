# Lens overlay geometry: crop-edge device check

Checks on a real device that the aspect-fill mapping (`LensOverlayGeometry.viewRect`) puts each
hologram label on the right face, including faces near the left and right crop edges. Unit tests
cover the math (`Packages/HaloKit/Tests/HaloUITests/LensOverlayGeometryTests.swift`); this check
covers what they can't: preview rotation, the layer's actual crop, and the frame/view sizes on the
device.

## Why the edges matter

`CameraSource` delivers 1280x720 buffers tagged `.right`, so the upright frame is 720x1280 (9:16).
A 19.5:9 iPhone's portrait view is narrower than that, so `.resizeAspectFill` crops the frame's left
and right sides. On a 390x844 pt view, for example, the frame is drawn 474.75 pt wide, which crops
about 42 pt per side. A mapping that ignores the crop (`x * viewWidth`) is correct at the centre and
gets worse towards the edges: up to about 42 pt at the left and right borders, roughly a face's width
at conversational distance.

## Setup

- A 19.5:9 iPhone (any iPhone with Face ID, e.g. iPhone 15/16/17), portrait, running a build with
  the face model installed (no "Recognition unavailable" banner).
- One volunteer who is enrolled and confirmed in Halo, and one who is not enrolled. Use
  consenting test people only. Don't record or commit any images.
- Good, even lighting. Stand 1–2 m away.

## Steps

1. Open the Lens tab. Turn on the debug metrics toggle (speedometer, bottom right) and check that
   fps is about 30.
2. **Centre:** the enrolled person stands centred in the preview. Wait for the label.
   - Expect: the label is horizontally centred over their head (leader line ends at the top centre
     of the face) and follows them as they move.
3. **Left edge:** the person steps left until their face is about 10–15% of the screen width from
   the left edge, still fully visible.
   - Expect: the label stays horizontally centred over their face (the leader line still ends at
     the top centre of the face, not to its right). It is clamped inside the screen only when the
     face is closer to the edge than half the label's width.
4. **Right edge:** repeat step 3 on the right side.
5. **Into the crop:** the person keeps moving until their face leaves the visible preview.
   - Expect: the label slides off with the face, or is clamped at the edge, and disappears when
     the track is lost. It never jumps to another face.
6. **Two people:** the enrolled person on the left edge and the non-enrolled person on the right
   edge, then swap sides.
   - Expect: the label stays on the enrolled person's face throughout. The non-enrolled person gets
     only a faint ring with no text (invariant 1).
7. **Ring alignment:** with the non-enrolled person at each edge, check that the ring is centred on
   their face and about face-sized.

## Pass criteria

- In steps 2–4 the label's leader line ends within about 10 pt of the top centre of the face.
- A label never appears over the wrong person, and a non-enrolled face never shows text.
- If labels drift towards the screen centre as faces approach the edges, the crop offset isn't being
  applied. If they are off by a constant rotation or mirror, check the preview connection's
  `videoRotationAngle` (should be 90) against `CameraSource.portraitOrientation` (`.right`).

## Record

The device model, iOS version, and pass/fail for each step. Text only: no screenshots of real people.
