import 'dart:convert';

import 'ai_error.dart';
import 'ai_types.dart';
import 'wire.dart';

/// OpenAI-compatible Chat Completions (OpenAI, OpenRouter, NVIDIA NIM, Reka,
/// Ollama, LM Studio, vLLM, ...).
class OpenAiWire extends LlmWire {
  const OpenAiWire();

  @override
  String get id => 'openai';

  @override
  String normalizeBaseUrl(String baseUrl) {
    var b = super.normalizeBaseUrl(baseUrl);
    // Users sometimes paste the full endpoint.
    if (b.endsWith('/chat/completions')) {
      b = b.substring(0, b.length - '/chat/completions'.length);
    }
    return b;
  }

  @override
  Uri buildUrl(String baseUrl, String model, {required bool stream}) =>
      Uri.parse('${normalizeBaseUrl(baseUrl)}/chat/completions');

  @override
  Map<String, String> buildHeaders(String apiKey) => {
        'Content-Type': 'application/json; charset=utf-8',
        if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

  /// Optional attribution header OpenRouter accepts. [verify] against their docs.
  static Map<String, String> extraHeaders(String baseUrl) =>
      baseUrl.contains('openrouter.ai') ? const {'X-Title': 'Physiqo'} : const {};

  @override
  Map<String, dynamic> buildBody(WireRequest r, {String baseUrl = ''}) {
    final isOpenAiHost = baseUrl.contains('api.openai.com');
    // [verify] OpenAI reasoning families reject `max_tokens`.
    final usesCompletionTokens =
        isOpenAiHost && RegExp(r'^(o\d|gpt-5)').hasMatch(r.model);

    return {
      'model': r.model,
      'messages': r.turns.map(_turnToMessage).toList(),
      // Never send an empty tools array: several servers reject it.
      if (r.hasTools) 'tools': r.tools,
      if (r.stream) 'stream': true,
      // [verify] only OpenAI itself is known to accept stream_options.
      if (r.stream && isOpenAiHost) 'stream_options': {'include_usage': true},
      if (r.maxTokens != null)
        (usesCompletionTokens ? 'max_completion_tokens' : 'max_tokens'): r.maxTokens,
    };
  }

  static Map<String, dynamic> _turnToMessage(AiTurn t) {
    switch (t.role) {
      case AiRole.system:
        return {'role': 'system', 'content': t.text};
      case AiRole.user:
        if (t.images.isEmpty) return {'role': 'user', 'content': t.text};
        return {
          'role': 'user',
          'content': [
            for (final img in t.images)
              {
                'type': 'image_url',
                'image_url': {'url': img.dataUrl},
              },
            if (t.text.isNotEmpty) {'type': 'text', 'text': t.text},
          ],
        };
      case AiRole.assistant:
        return {
          'role': 'assistant',
          'content': t.text,
          if (t.toolCalls.isNotEmpty)
            'tool_calls': [
              for (final c in t.toolCalls)
                {
                  'id': c.id,
                  'type': 'function',
                  'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)},
                },
            ],
        };
      case AiRole.tool:
        return {
          'role': 'tool',
          'tool_call_id': t.toolCallId ?? '',
          'content': t.text,
        };
    }
  }

  @override
  WireParser newParser({String provider = '', String model = ''}) =>
      OpenAiParser(provider: provider, model: model);
}

class _PendingCall {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}

class OpenAiParser implements WireParser {
  final String provider;
  final String model;
  OpenAiParser({this.provider = '', this.model = ''});

  final StringBuffer _text = StringBuffer();
  final Map<String, _PendingCall> _calls = {};
  final List<String> _order = [];
  String? _lastKey;
  String? _finish;
  int? _in;
  int? _out;
  bool _sawReasoning = false;
  int _idCounter = 0;

  @override
  String addChunk(Map<String, dynamic> chunk) {
    if (chunk['error'] != null) {
      throw AiErrorMapper.fromStreamErrorObject(chunk['error'],
          provider: provider, model: model);
    }

    final usage = chunk['usage'];
    if (usage is Map) {
      final i = usage['prompt_tokens'];
      final o = usage['completion_tokens'];
      if (i is int) _in = i;
      if (o is int) _out = o;
    }

    final choices = chunk['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final choice = choices[0];
    if (choice is! Map) return '';

    final fr = choice['finish_reason'];
    if (fr is String) _finish = fr;

    final isFull = choice['message'] is Map;
    final body = (isFull ? choice['message'] : choice['delta']);
    if (body is! Map) return '';

    var visible = '';
    final content = body['content'];
    if (content is String && content.isNotEmpty) {
      _text.write(content);
      visible = content;
    }
    final reasoning = body['reasoning_content'] ?? body['reasoning'];
    if (reasoning is String && reasoning.isNotEmpty) _sawReasoning = true;

    final tcs = body['tool_calls'];
    if (tcs is List) {
      for (final tc in tcs) {
        if (tc is Map) _addToolCallPart(tc, isFull);
      }
    }
    return visible;
  }

  void _addToolCallPart(Map tc, bool isFull) {
    final fn = tc['function'] is Map ? tc['function'] as Map : const {};
    final id = tc['id'] is String ? tc['id'] as String : '';
    final index = tc['index'];
    final name = fn['name'] is String ? fn['name'] as String : '';
    final args = fn['arguments'];

    String key;
    if (isFull) {
      // Non-streamed: every entry is a distinct, complete call.
      key = 'full${_order.length}';
    } else if (index is int) {
      key = 'i$index';
      final existing = _calls[key];
      // Some servers reuse index 0 for every parallel call but give each a
      // distinct id: a new non-empty id on an occupied slot is a new call.
      if (existing != null && id.isNotEmpty && existing.id.isNotEmpty && existing.id != id) {
        key = 'i$index#$id';
      }
    } else if (id.isNotEmpty) {
      key = 'id$id';
    } else {
      key = _lastKey ?? 'i0';
    }

    final p = _calls.putIfAbsent(key, () {
      _order.add(key);
      return _PendingCall();
    });
    _lastKey = key;
    if (id.isNotEmpty && p.id.isEmpty) p.id = id;
    if (name.isNotEmpty) p.name = name;
    if (args is String) {
      p.args.write(args);
    } else if (args is Map) {
      p.args.write(jsonEncode(args));
    }
  }

  @override
  WireResult finish() {
    final calls = <AiToolCall>[];
    for (final key in _order) {
      final p = _calls[key]!;
      if (p.name.isEmpty) continue;
      final parsed = decodeArgs(p.args.toString());
      if (parsed == null) {
        // Truncated or invalid arguments: never silently drop the call.
        throw AiError(AiErrorKind.malformed,
            provider: provider, model: model, detail: 'tool arguments are not valid JSON');
      }
      _idCounter++;
      calls.add(AiToolCall(
        id: p.id.isNotEmpty
            ? p.id
            : 'call_${DateTime.now().microsecondsSinceEpoch}_$_idCounter',
        name: p.name,
        arguments: parsed,
      ));
    }
    final text = _text.toString();
    return WireResult(
      text: text,
      toolCalls: calls,
      finishReason: _finish,
      inputTokens: _in,
      outputTokens: _out,
      reasoningOnly: _sawReasoning && text.trim().isEmpty && calls.isEmpty,
    );
  }
}
