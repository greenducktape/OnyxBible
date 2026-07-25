import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Set to true the first time any store has to recover a file from its `.bak`
/// (i.e. the primary JSON was missing or corrupt). The reader surfaces a single
/// non-fatal notice so silent data loss never goes unannounced.
bool gDataRecovered = false;

// Serialises writes per target path. Callers fire saves without awaiting them
// (pen-lift flush, debounce timers), so two writes to the same file can overlap;
// both would open the SAME `.tmp`, the later open truncating under the earlier
// writer — and the corrupt result would then be renamed over the good primary.
// Chaining each path's writes behind the previous one removes the race.
final Map<String, Future<void>> _writeChains = {};

/// Writes [data] (JSON-encoded) to [file] atomically so a crash or power loss on
/// an e-ink device can never leave a half-written primary file:
///   1. serialise to a sibling `<path>.tmp` and flush it to disk,
///   2. copy the current good file aside as `<path>.bak`,
///   3. rename the temp over the target (atomic on the same filesystem).
/// After a crash the worst case is a stale `.tmp` (ignored) or a readable
/// `.bak` (used by [readJsonResilient]) — the primary is always whole.
/// Concurrent calls for the same path are queued, never interleaved.
Future<void> writeJsonAtomic(File file, Object data) {
  final prev = _writeChains[file.path] ?? Future<void>.value();
  // Errors are swallowed per link so one failed write can't poison the chain.
  final next = prev
      .then((_) => _writeJsonAtomicNow(file, data))
      .catchError((Object e) => debugPrint('Atomic write failed: $e'));
  _writeChains[file.path] = next;
  return next;
}

Future<void> _writeJsonAtomicNow(File file, Object data) async {
  final encoded = json.encode(data);
  final tmp = File('${file.path}.tmp');
  final raf = await tmp.open(mode: FileMode.write);
  try {
    await raf.writeString(encoded);
    await raf.flush(); // force the bytes to disk before we swap it in
  } finally {
    await raf.close();
  }
  // Keep the previous good copy as .bak before replacing it, so a future
  // corrupt write is still recoverable.
  if (await file.exists()) {
    try {
      await file.copy('${file.path}.bak');
    } catch (_) {/* best effort — the temp swap below is what matters */}
  }
  await tmp.rename(file.path);
}

/// Decoded JSON plus whether it came from the `.bak` fallback.
class JsonRead {
  final dynamic data; // Map / List, or null when nothing parsed
  final bool recovered;
  const JsonRead(this.data, this.recovered);
}

/// Reads and decodes [file], falling back to its `.bak` when the primary is
/// absent, empty, or unparseable. Returns `JsonRead(null, false)` when neither
/// yields valid JSON (a genuinely fresh install or total loss). When the `.bak`
/// had to be used, sets [gDataRecovered] so the UI can show a one-time notice.
Future<JsonRead> readJsonResilient(File file) async {
  final candidates = <(File, bool)>[
    (file, false),
    (File('${file.path}.bak'), true),
  ];
  for (final (f, isBak) in candidates) {
    try {
      if (!await f.exists()) continue;
      final s = await f.readAsString();
      if (s.isEmpty) continue;
      final decoded = json.decode(s);
      if (isBak) {
        gDataRecovered = true;
        debugPrint('Recovered ${file.path} from .bak');
      }
      return JsonRead(decoded, isBak);
    } catch (e) {
      debugPrint('Failed reading ${f.path}: $e');
      // Fall through to the next candidate (.bak), or give up.
    }
  }
  return const JsonRead(null, false);
}
