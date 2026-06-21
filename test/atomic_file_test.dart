import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/atomic_file.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atomic_test');
    gDataRecovered = false;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File f(String name) => File('${dir.path}/$name');

  test('writeJsonAtomic writes readable JSON and replaces prior content',
      () async {
    final file = f('data.json');
    await writeJsonAtomic(file, {'a': 1});
    expect(json.decode(await file.readAsString()), {'a': 1});

    await writeJsonAtomic(file, {'a': 2, 'b': 3});
    expect(json.decode(await file.readAsString()), {'a': 2, 'b': 3});
    // No leftover temp file after a successful write.
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('the previous good copy is kept as .bak', () async {
    final file = f('data.json');
    await writeJsonAtomic(file, {'v': 1});
    await writeJsonAtomic(file, {'v': 2});
    expect(json.decode(await File('${file.path}.bak').readAsString()), {'v': 1});
  });

  test('readJsonResilient returns the primary when it is valid', () async {
    final file = f('data.json');
    await writeJsonAtomic(file, {'ok': true});
    final r = await readJsonResilient(file);
    expect(r.data, {'ok': true});
    expect(r.recovered, isFalse);
    expect(gDataRecovered, isFalse);
  });

  test('readJsonResilient falls back to .bak when the primary is corrupt',
      () async {
    final file = f('data.json');
    await writeJsonAtomic(file, {'v': 1}); // becomes .bak on next write
    await writeJsonAtomic(file, {'v': 2});
    // Corrupt the primary (simulate a torn write) but leave the .bak intact.
    await file.writeAsString('{ this is not valid json');

    final r = await readJsonResilient(file);
    expect(r.data, {'v': 1}); // recovered the last good copy
    expect(r.recovered, isTrue);
    expect(gDataRecovered, isTrue);
  });

  test('readJsonResilient returns null when nothing parses', () async {
    final r = await readJsonResilient(f('missing.json'));
    expect(r.data, isNull);
    expect(r.recovered, isFalse);
  });
}
