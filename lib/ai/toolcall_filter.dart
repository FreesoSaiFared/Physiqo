import 'dart:convert';

import 'ai_types.dart';

/// Decides which part of a streaming text is safe to show.
///
/// Some models write tool calls as text: `<TOOLCALL>[...]</TOOLCALL>` or a bare
/// JSON object. That text must never reach the screen, so it is held back.
class ToolCallTextFilter {
  static const String openTag = '<TOOLCALL>';
  static const String closeTag = '</TOOLCALL>';

  final StringBuffer _full = StringBuffer();
  int _emitted = 0;

  String get fullText => _full.toString();

  /// Feeds [delta]; returns the newly visible text (possibly empty).
  String feed(String delta) {
    _full.write(delta);
    final full = _full.toString();

    int safeEnd;
    final tagAt = full.indexOf(openTag);
    if (tagAt != -1) {
      safeEnd = tagAt;
    } else if (full.trimLeft().startsWith('{')) {
      // Possibly a bare JSON tool call: hold everything back until the end.
      safeEnd = 0;
    } else {
      // Hold back a trailing partial "<TOOLCALL" prefix.
      var hold = 0;
      final maxK = openTag.length - 1 < full.length ? openTag.length - 1 : full.length;
      for (var k = maxK; k >= 1; k--) {
        if (full.endsWith(openTag.substring(0, k))) {
          hold = k;
          break;
        }
      }
      safeEnd = full.length - hold;
    }

    if (safeEnd <= _emitted) return '';
    final out = full.substring(_emitted, safeEnd);
    _emitted = safeEnd;
    return out;
  }
}

/// Final text/tool-call extraction used once a response is complete.
class ToolCallText {
  /// Pulls text-embedded tool calls out of [text].
  /// Returns the cleaned visible text and any calls found.
  static ({String text, List<AiToolCall> calls}) extract(
    String text,
    List<AiToolCall> Function(String json) parseCalls,
  ) {
    final start = text.indexOf(ToolCallTextFilter.openTag);
    if (start != -1) {
      final jsonStart = start + ToolCallTextFilter.openTag.length;
      var end = text.indexOf(ToolCallTextFilter.closeTag, jsonStart);
      final hasClose = end != -1;
      if (!hasClose) end = text.length;
      var json = text.substring(jsonStart, end).trim();
      if (json.startsWith('```')) {
        final nl = json.indexOf('\n');
        if (nl != -1) json = json.substring(nl + 1);
        if (json.endsWith('```')) {
          json = json.substring(0, json.length - 3).trim();
        }
      }
      final before = text.substring(0, start).trim();
      final after = hasClose
          ? text.substring(end + ToolCallTextFilter.closeTag.length).trim()
          : '';
      final visible = [before, after].where((s) => s.isNotEmpty).join('\n\n');
      return (text: visible, calls: parseCalls(json));
    }
    if (text.trim().startsWith('{')) {
      final calls = parseCalls(text);
      if (calls.isNotEmpty) return (text: '', calls: calls);
    }
    return (text: text, calls: const <AiToolCall>[]);
  }
}

/// Parses tool calls that a model wrote as plain JSON text.
/// Understands `{"tool_calls": [...]}`, `{"name":..., "parameters"|"arguments":...}`,
/// `{"function": {...}}` and lists of those. Never throws.
class FallbackToolCallParser {
  static int _counter = 0;

  static String _newId(dynamic given) {
    if (given != null && given.toString().isNotEmpty) return given.toString();
    _counter++;
    return 'call_${DateTime.now().microsecondsSinceEpoch}_$_counter';
  }

  static Map<String, dynamic> _args(dynamic raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    if (raw is String) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) return d.cast<String, dynamic>();
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  static List<AiToolCall> parse(String content) {
    try {
      final trimmed = content.trim();
      if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return [];
      final parsed = jsonDecode(trimmed);
      final calls = <AiToolCall>[];

      void addFromMap(Map map) {
        if (map['tool_calls'] is List) {
          for (final call in map['tool_calls'] as List) {
            if (call is Map) {
              final fn = call['function'] is Map ? call['function'] as Map : call;
              final name = fn['name']?.toString() ?? '';
              if (name.isEmpty) continue;
              calls.add(AiToolCall(
                id: _newId(call['id']),
                name: name,
                arguments: _args(fn['arguments'] ?? fn['parameters']),
              ));
            }
          }
        } else if (map.containsKey('name')) {
          final name = map['name']?.toString();
          if (name != null && name.isNotEmpty) {
            calls.add(AiToolCall(
              id: _newId(map['id']),
              name: name,
              arguments: _args(map['parameters'] ?? map['arguments']),
            ));
          }
        } else if (map['function'] is Map) {
          final fn = map['function'] as Map;
          final name = fn['name']?.toString();
          if (name != null && name.isNotEmpty) {
            calls.add(AiToolCall(
              id: _newId(map['id']),
              name: name,
              arguments: _args(fn['arguments']),
            ));
          }
        }
      }

      if (parsed is Map) {
        addFromMap(parsed);
      } else if (parsed is List) {
        for (final item in parsed) {
          if (item is Map) addFromMap(item);
        }
      }
      return calls;
    } catch (_) {
      return [];
    }
  }
}
