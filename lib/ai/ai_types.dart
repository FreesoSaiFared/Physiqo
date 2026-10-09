/// Shared value types for the AI layer.
///
/// The conversation is modelled as a list of [AiTurn]s (not OpenAI-shaped
/// maps). One assistant turn holds ALL of its text and tool calls; each wire
/// adapter serializes the turns to its own format.
library;

class AiToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  /// Opaque provider data that must be echoed back on the next request
  /// (Gemini `thoughtSignature`). Null for providers that don't use it.
  final String? thoughtSignature;

  AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.thoughtSignature,
  });
}

class AiResponse {
  final String? text;
  final List<AiToolCall>? toolCalls;
  final String? providerServed;
  AiResponse({this.text, this.toolCalls, this.providerServed});
}

class AiImage {
  final String mime;
  final String base64;
  const AiImage({required this.mime, required this.base64});

  String get dataUrl => 'data:$mime;base64,$base64';
}

enum AiRole { system, user, assistant, tool }

class AiTurn {
  final AiRole role;
  final String text;
  final List<AiImage> images;

  /// Assistant turns: every tool call the model emitted in this turn.
  final List<AiToolCall> toolCalls;

  /// Tool turns: which call this is the result of.
  final String? toolCallId;
  final String? toolName;

  const AiTurn({
    required this.role,
    this.text = '',
    this.images = const [],
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });
}

/// Everything a wire adapter needs to build one HTTP request.
class WireRequest {
  final String model;
  final List<AiTurn> turns;

  /// OpenAI-style tool definitions (`{type: function, function: {...}}`).
  /// Null or empty means "no tools": the key is omitted from the payload.
  final List<Map<String, dynamic>>? tools;
  final bool stream;
  final int? maxTokens;

  const WireRequest({
    required this.model,
    required this.turns,
    this.tools,
    this.stream = true,
    this.maxTokens,
  });

  bool get hasTools => tools != null && tools!.isNotEmpty;
}
