import '../ai/ai_types.dart';

/// One event of an AI response stream.
///
/// * [deltaText] is a TRUE delta (only the newly arrived visible text).
/// * [reset] tells the UI to discard text received so far (a failed attempt
///   is being retried on another model).
/// * On the final event ([isDone]) [finalText] is the authoritative full
///   answer (text-embedded tool calls already removed) and [toolCalls] holds
///   every tool call.
class AiStreamEvent {
  final String deltaText;
  final bool isDone;
  final bool reset;
  final String? finalText;
  final List<AiToolCall>? toolCalls;
  final String? providerServed;

  AiStreamEvent({
    this.deltaText = '',
    this.isDone = false,
    this.reset = false,
    this.finalText,
    this.toolCalls,
    this.providerServed,
  });
}
