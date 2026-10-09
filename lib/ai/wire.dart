import 'dart:convert';

import 'ai_types.dart';

/// Result of parsing one complete model response (streamed or not).
class WireResult {
  final String text;
  final List<AiToolCall> toolCalls;
  final String? finishReason;
  final int? inputTokens;
  final int? outputTokens;

  /// The model produced hidden reasoning but no visible answer.
  final bool reasoningOnly;

  const WireResult({
    required this.text,
    required this.toolCalls,
    this.finishReason,
    this.inputTokens,
    this.outputTokens,
    this.reasoningOnly = false,
  });
}

/// Incremental parser for one response. Feed it decoded JSON chunks.
abstract class WireParser {
  /// Consumes one decoded JSON object; returns newly arrived visible text
  /// (a true delta, possibly empty). May throw an `AiError` when the chunk is
  /// an error object.
  String addChunk(Map<String, dynamic> chunk);

  /// Call once at end of stream. May throw `AiError` (blocked / malformed).
  WireResult finish();
}

/// One provider wire format.
abstract class LlmWire {
  const LlmWire();

  String get id;

  /// Final request URL. The API key is NEVER part of the URL.
  Uri buildUrl(String baseUrl, String model, {required bool stream});

  Map<String, String> buildHeaders(String apiKey);

  Map<String, dynamic> buildBody(WireRequest r, {String baseUrl = ''});

  WireParser newParser({String provider = '', String model = ''});

  /// Normalizes a user-typed base URL (trim, no trailing slash).
  String normalizeBaseUrl(String baseUrl) {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }
}

/// Tool-call arguments from a JSON string or a map.
/// Returns null when the value is present but is not a valid JSON object
/// (for example truncated), so callers can treat it as malformed.
Map<String, dynamic>? decodeArgs(dynamic raw) {
  if (raw == null) return <String, dynamic>{};
  if (raw is Map) return raw.cast<String, dynamic>();
  if (raw is String) {
    final t = raw.trim();
    if (t.isEmpty) return <String, dynamic>{};
    try {
      final d = jsonDecode(t);
      if (d is Map) return d.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }
  return null;
}
