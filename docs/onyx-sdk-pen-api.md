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

`com.onyx.android.sdk.pen.*`, all static. Parameter NAMES are the real ones,
read from each method's LocalVariableTable (`javap -l`) — the AAR kept its debug
info. Worth having: the argument roles are not guessable from the types, and
three of these methods take consecutive floats.

```java
NeoFountainPen.drawStroke(Canvas canvas, Paint paint, List<TouchPoint> points,
                          float displayScale, float strokeWidth,
                          float maxTouchPressure, boolean erase);

NeoBrushPen.drawStroke(Canvas canvas, Paint paint, List<TouchPoint> points,
                       float strokeWidth, float maxTouchPressure,
                       boolean erase);

NeoMarkerPen.drawStroke(Canvas canvas, Paint paint, List<TouchPoint> list,
                        float strokeWidth, boolean erase);

NeoCharcoalPen.drawNormalStroke(Context context, Canvas canvas, Paint paint,
                                List<TouchPoint> points, int color,
                                float strokeWidth, ShapeCreateArgs createArgs,
                                Matrix screenMatrix, boolean erase);

PenUtils.drawStrokeByPointSize(Canvas canvas, Paint paint,
                               List<TouchPoint> points, boolean erase);

NeoPenUtils.computeStrokePoints(int type, List<TouchPoint> points,
                                float strokeWidth, float maxTouchPressure);
```

Note the fountain pen takes `displayScale` FIRST of the three floats, where the
brush takes `strokeWidth` — pass points already in panel pixels and it wants
1.0. There is no getter anywhere for `maxTouchPressure`; Onyx panels report
4096.

The plain pen/pencil style (`TouchHelper.STROKE_STYLE_PENCIL`) has no dedicated
`Neo*` class; `PenUtils.drawStrokeByPointSize(Canvas, Paint, List<TouchPoint>,
boolean)` appears to be its path.

Helpers worth knowing about:

```java
PenUtils.ensurePenBitmapCreated(Rect drawRect);  // a bitmap sized for pen output
PenUtils.toTouchPoints(NeoRenderPoint[] points);
PenUtils.getPointArray(List<TouchPoint> points, float maxTouchPressure);
```

`NeoPenUtils.computeStrokePoints` takes a `TouchHelper.STROKE_STYLE_*` constant
as its `type`, so it is the one entry point that covers every style.

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

## How the app uses it

`OnyxStrokeRenderer` (in the vendored plugin) draws a page's strokes into a
bitmap with these and returns a PNG. Flutter keeps owning strokes, storage,
erasing and undo, and falls back to its own painter whenever native rendering
isn't available or hasn't landed yet.

## What this took

Drawing committed ink with these means it can no longer be a Flutter
`CustomPainter` — they need an Android `Canvas`. The least invasive shape is:
Flutter keeps owning strokes, storage, erase and undo, and asks the native side
to render a page's strokes into a bitmap, which it then draws under the text. A
round trip per page render (and per erase/undo), against ink that matches the
SDK's exactly because it *is* the SDK's.

Non-Onyx devices have none of this, so the Dart renderer in `_paintStroke` has
to stay as the fallback regardless.
