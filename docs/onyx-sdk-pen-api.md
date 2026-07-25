# Onyx SDK pen API

The stroke the SDK draws while you write and the stroke this app renders
afterwards are produced by two different pieces of code, which is why they never
look quite the same. The SDK ships the renderers it uses for the raw layer as
public static methods that draw onto an ordinary `android.graphics.Canvas` — so
committed ink *can* be drawn by the same code instead of imitating it.

These signatures were read out of the AARs Gradle downloads for the build
(`onyxsdk-pen:1.4.12`, `onyxsdk-base:1.7.7`) with `javap`. Recorded here because
`repo.boox.com` is not reachable from every environment, and Onyx publishes no
API docs for these classes.

## The point type

`com.onyx.android.sdk.data.note.TouchPoint` (onyxsdk-base) — every renderer
below consumes a `List<TouchPoint>`:

```java
public float x, y, pressure, size;
public int tiltX, tiltY;
public long timestamp;

public TouchPoint(float x, float y, float pressure, float size, long timestamp);
public TouchPoint(float x, float y, float pressure, float size,
                  int tiltX, int tiltY, long timestamp);
public TouchPoint(android.view.MotionEvent e);
```

Note `size` and the tilt fields, which the app currently captures nothing
equivalent to, and `timestamp`, which it only started recording separately.

## The renderers

`com.onyx.android.sdk.pen.*`, all static:

```java
NeoFountainPen.drawStroke(Canvas, Paint, List<TouchPoint> points,
                          float, float, float, boolean);
NeoFountainPen.computeStrokePoints(List<TouchPoint>, float, float, float);
NeoFountainPen.hasPressure(List<TouchPoint>);

NeoBrushPen.drawStroke(Canvas, Paint, List<TouchPoint>, float, float, boolean);
NeoBrushPen.computeStrokePoints(List<TouchPoint>, float, float);

NeoMarkerPen.drawStroke(Canvas, Paint, List<TouchPoint>, float, boolean);
NeoMarkerPen.computeStrokePoints(List<TouchPoint>, float, float);

NeoCharcoalPen.drawNormalStroke(Context, Canvas, Paint, List<TouchPoint>,
                                int, float, ShapeCreateArgs, Matrix, boolean);
NeoCharcoalPen.drawBigStroke(Context, Canvas, Paint, List<TouchPoint>, Matrix,
                             int, float, ShapeCreateArgs, Matrix, boolean);
```

The plain pen/pencil style (`TouchHelper.STROKE_STYLE_PENCIL`) has no dedicated
`Neo*` class; `PenUtils.drawStrokeByPointSize(Canvas, Paint, List<TouchPoint>,
boolean)` appears to be its path.

Helpers worth knowing about:

```java
PenUtils.ensurePenBitmapCreated(Rect);          // a bitmap sized for pen output
PenUtils.toTouchPoints(NeoRenderPoint[]);
NeoPenUtils.computeStrokePoints(int strokeStyle, List<TouchPoint>, float, float);
```

`NeoPenUtils.computeStrokePoints` takes a `TouchHelper.STROKE_STYLE_*` constant,
so it is the one entry point that covers every style.

## Stroke styles

`TouchHelper` constants, as mapped in `OnyxsdkPenArea.strokeStyleToOnyx`:

| App preset | `TouchHelper` constant   |
|------------|--------------------------|
| Ballpoint  | `STROKE_STYLE_PENCIL`    |
| Fountain   | `STROKE_STYLE_FOUNTAIN`  |
| Brush      | `STROKE_STYLE_NEO_BRUSH` |
| Pencil     | `STROKE_STYLE_CHARCOAL`  |
| Marker     | `STROKE_STYLE_MARKER`    |

The SDK also has `STROKE_STYLE_DASH` and `STROKE_STYLE_CHARCOAL_V2` (with a
matching `NeoCharcoalPenV2` class), neither of which the app offers.

## What this would take

Drawing committed ink with these means it can no longer be a Flutter
`CustomPainter` — they need an Android `Canvas`. The least invasive shape is:
Flutter keeps owning strokes, storage, erase and undo, and asks the native side
to render a page's strokes into a bitmap, which it then draws under the text. A
round trip per page render (and per erase/undo), against ink that matches the
SDK's exactly because it *is* the SDK's.

Non-Onyx devices have none of this, so the Dart renderer in `_paintStroke` has
to stay as the fallback regardless.
