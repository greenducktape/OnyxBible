import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'verse.dart';

/// The single, canonical verse-id constructor. Kept identical across every
/// source so handwritten notes (keyed "Book_Chapter_Verse") stay compatible
/// regardless of which translation/source produced the verse.
String verseId(String book, int chapter, int verse) => '${book}_${chapter}_$verse';

/// Metadata for a translation the app can show. Adding a new bundled language
/// (e.g. Spanish RV1909, German Luther1912) is just: drop its per-book JSON
/// under assets/bibles/<id>/ and add an entry here.
class TranslationInfo {
  final String id; // also the asset folder name, e.g. 'kjv'
  final String displayName;
  final String language;
  final bool bundled; // true => offline asset; false => fetched via API
  final String attribution;

  const TranslationInfo({
    required this.id,
    required this.displayName,
    required this.language,
    required this.bundled,
    required this.attribution,
  });
}

const List<TranslationInfo> kTranslations = [
  TranslationInfo(
    id: 'kjv',
    displayName: 'King James Version',
    language: 'English',
    bundled: true,
    attribution: 'Public Domain',
  ),
  // Planned additions (bundled, public domain):
  //   WEB  — World English Bible (English, modern)
  //   rv1909 — Reina-Valera 1909 (Spanish)
  //   luther1912 — Luther 1912 (German)
  // Additional translations may also be served via ApiScriptureSource.
];

const String kDefaultTranslation = 'kjv';

TranslationInfo translationById(String id) =>
    kTranslations.firstWhere((t) => t.id == id,
        orElse: () => kTranslations.first);

class ScriptureUnavailable implements Exception {
  final String message;
  const ScriptureUnavailable([this.message = 'Scripture unavailable']);
  @override
  String toString() => 'ScriptureUnavailable: $message';
}

abstract class ScriptureSource {
  String get translationId;
  Future<List<Verse>> chapter(String book, int chapter);
}

/// Reads scripture from bundled per-book JSON assets. The asset *is* the cache,
/// so only a tiny per-book decoded-JSON memory cache is kept.
class BundledScriptureSource implements ScriptureSource {
  @override
  final String translationId;
  final Map<String, Map<String, dynamic>> _bookCache = {};

  BundledScriptureSource(this.translationId);

  String _assetPath(String book) =>
      'assets/bibles/$translationId/${book.replaceAll(' ', '_')}.json';

  @override
  Future<List<Verse>> chapter(String book, int chapter) async {
    var decoded = _bookCache[book];
    if (decoded == null) {
      try {
        decoded = json.decode(await rootBundle.loadString(_assetPath(book)))
            as Map<String, dynamic>;
      } catch (_) {
        throw ScriptureUnavailable('Missing asset for $book');
      }
      _bookCache[book] = decoded;
    }
    final chapters = decoded['chapters'] as Map<String, dynamic>;
    final raw = chapters['$chapter'] as List?;
    if (raw == null) throw ScriptureUnavailable('$book $chapter not found');
    return raw.map((e) {
      final m = e as Map<String, dynamic>;
      final n = (m['v'] as num).toInt();
      return Verse(
          id: verseId(book, chapter, n),
          number: n,
          text: (m['t'] as String).trim());
    }).toList();
  }
}

/// Fetches a (non-bundled) translation from bible-api.com. Used only for
/// translations not shipped as assets.
class ApiScriptureSource implements ScriptureSource {
  @override
  final String translationId;

  ApiScriptureSource(this.translationId);

  @override
  Future<List<Verse>> chapter(String book, int chapter) async {
    final uri = Uri.parse(
        'https://bible-api.com/${Uri.encodeComponent('$book $chapter')}'
        '?translation=$translationId');
    final resp = await http.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw ScriptureUnavailable('HTTP ${resp.statusCode}');
    }
    final data = json.decode(resp.body);
    final list = data['verses'] as List?;
    if (list == null || list.isEmpty) {
      throw const ScriptureUnavailable('No verses returned');
    }
    return list.map((v) {
      final n = (v['verse'] as num).toInt();
      return Verse(
          id: verseId(book, chapter, n),
          number: n,
          text: v['text'].toString().trim());
    }).toList();
  }
}

ScriptureSource sourceFor(TranslationInfo t) =>
    t.bundled ? BundledScriptureSource(t.id) : ApiScriptureSource(t.id);
