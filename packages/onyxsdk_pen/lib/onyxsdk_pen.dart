import 'dart:typed_data';

import 'src/onyxsdk_pen_platform_interface.dart';

export 'src/onyx_stroke_style.dart';
export 'src/onyxsdk_pen_area.dart';
export 'src/onyxsdk_pen_platform_interface.dart';

class OnyxsdkPen {
  Future<bool> isOnyxDevice() {
    return OnyxsdkPenPlatform.instance.isOnyxDevice();
  }

  Future<double?> displayDpi() {
    return OnyxsdkPenPlatform.instance.displayDpi();
  }

  /// Renders finished strokes with the SDK's OWN pen renderers — the same ones
  /// that draw the raw ink under the nib — into a transparent bitmap of
  /// [width] x [height] physical pixels, returned as PNG bytes.
  ///
  /// Returns null when the SDK can't do it (a non-Onyx device, no strokes, an
  /// allocation failure). Callers must keep their own renderer for that case.
  ///
  /// Each stroke map carries:
  ///  - `style`: int, a native stroke-style constant (see [OnyxStrokeStyle])
  ///  - `color`: int, ARGB
  ///  - `width`: double, nib width in the same physical pixels
  ///  - `points`: `List<double>`, flattened five per point — x, y, pressure,
  ///    size, timestamp. Flattened because a page of handwriting runs to tens
  ///    of thousands of points and the channel codec charges per object.
  Future<Uint8List?> renderStrokes({
    required int width,
    required int height,
    required List<Map<String, Object?>> strokes,
  }) {
    return OnyxsdkPenPlatform.instance
        .renderStrokes(width: width, height: height, strokes: strokes);
  }
}
