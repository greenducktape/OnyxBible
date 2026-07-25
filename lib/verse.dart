// The Verse model, extracted so both the UI and the data layer
// (scripture.dart) can depend on it without an import cycle.

class Verse {
  final String id;
  final int number;
  final String text;

  const Verse({required this.id, required this.number, required this.text});

  Map<String, dynamic> toJson() => {'id': id, 'number': number, 'text': text};

  factory Verse.fromJson(Map<String, dynamic> json) => Verse(
        id: json['id'] as String,
        number: (json['number'] as num).toInt(),
        text: json['text'] as String,
      );
}
