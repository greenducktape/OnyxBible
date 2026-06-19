import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'books.dart';
import 'reading_plan.dart';
import 'verse.dart';

/// The single, canonical verse-id constructor. Kept identical across every
/// source so handwritten notes (keyed "Book_Chapter_Verse") stay compatible
/// regardless of which translation/source produced the verse.
String verseId(String book, int chapter, int verse) => '${book}_${chapter}_$verse';

/// Inverse of [verseId]: splits "Book_Chapter_Verse" back into its parts.
/// Book names carry spaces (never underscores), so the last two underscore
/// segments are always chapter and verse. Returns null if malformed.
(String book, int chapter, int verse)? parseVerseId(String id) {
  final parts = id.split('_');
  if (parts.length < 3) return null;
  final verse = int.tryParse(parts.removeLast());
  final chapter = int.tryParse(parts.removeLast());
  if (verse == null || chapter == null || parts.isEmpty) return null;
  return (parts.join('_'), chapter, verse);
}

/// Metadata for a translation the app can show. Adding a new bundled language
/// (e.g. Spanish RV1909, German Luther1912) is just: drop its per-book JSON
/// under `assets/bibles/<id>/` and add an entry here.
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
  TranslationInfo(
    id: 'rv1909',
    displayName: 'Reina-Valera 1909',
    language: 'Español',
    bundled: true,
    attribution: 'Dominio público',
  ),
  TranslationInfo(
    id: 'luther1912',
    displayName: 'Luther 1912',
    language: 'Deutsch',
    bundled: true,
    attribution: 'Gemeinfrei (Public Domain)',
  ),
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

/// Loads the bundled chapter cross-reference graph used by reading plans.
Future<XrefGraph> loadXrefGraph() async {
  final raw = await rootBundle.loadString('assets/data/xref_chapters.json');
  return XrefGraph.fromJson(json.decode(raw) as Map<String, dynamic>);
}

class SearchHit {
  final String book;
  final int chapter;
  final int verse;
  final String text;

  const SearchHit({
    required this.book,
    required this.chapter,
    required this.verse,
    required this.text,
  });

  String get reference => '$book $chapter:$verse';
}

/// Case-insensitive full-text search over a bundled translation. Scans book
/// assets in canonical order and stops once [limit] hits are collected.
Future<List<SearchHit>> searchBundledTranslation(
  String translationId,
  String query, {
  int limit = 200,
}) async {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];

  final hits = <SearchHit>[];
  for (final book in kBibleBooks) {
    final path =
        'assets/bibles/$translationId/${book.name.replaceAll(' ', '_')}.json';
    Map<String, dynamic> decoded;
    try {
      decoded = json.decode(await rootBundle.loadString(path))
          as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final chapters = decoded['chapters'] as Map<String, dynamic>;
    for (final entry in chapters.entries) {
      final ch = int.parse(entry.key);
      for (final v in entry.value as List) {
        final m = v as Map<String, dynamic>;
        final text = m['t'] as String;
        if (text.toLowerCase().contains(q)) {
          hits.add(SearchHit(
              book: book.name,
              chapter: ch,
              verse: (m['v'] as num).toInt(),
              text: text));
          if (hits.length >= limit) return hits;
        }
      }
    }
  }
  return hits;
}
