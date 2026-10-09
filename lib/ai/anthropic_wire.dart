import 'ai_error.dart';
import 'ai_types.dart';
import 'wire.dart';

/// Anthropic native Messages API. [verify] every field against the current
/// docs and a real request before shipping; nothing here was run live.
class AnthropicWire extends LlmWire {
  const AnthropicWire();

  static const String apiVersion = '2023-06-01';

  @override
  String get id => 'anthropic';

  static bool matches(String baseUrl, String providerName) =>
      baseUrl.contains('api.anthropic.com') ||
      providerName.toLowerCase() == 'anthropic';

  @override
  Uri buildUrl(String baseUrl, String model, {required bool stream}) =>
      Uri.parse('${normalizeBaseUrl(baseUrl)}/messages');

  @override
  Map<String, String> buildHeaders(String apiKey) => {
        'Content-Type': 'application/json; charset=utf-8',
        'x-api-key': apiKey,
        'anthropic-version': apiVersion,
      };

  @override
  Map<String, dynamic> buildBody(WireRequest r, {String baseUrl = ''}) {
    final system = StringBuffer();
    final messages = <Map<String, dynamic>>[];

    void add(String role, List<Map<String, dynamic>> blocks) {
      if (blocks.isEmpty) return;
      // The API requires alternating roles: merge neighbours.
      if (messages.isNotEmpty && messages.last['role'] == role) {
        (messages.last['content'] as List).addAll(blocks);
      } else {
        messages.add({'role': role, 'content': blocks});
      }
    }

    for (final t in r.turns) {
      switch (t.role) {
        case AiRole.system:
          if (t.text.isNotEmpty) {
            if (system.isNotEmpty) system.write('\n\n');
            system.write(t.text);
          }
          break;
        case AiRole.user:
          add('user', [
            for (final img in t.images)
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': img.mime, 'data': img.base64},
              },
            if (t.text.isNotEmpty) {'type': 'text', 'text': t.text},
          ]);
          break;
        case AiRole.assistant:
          add('assistant', [
            if (t.text.isNotEmpty) {'type': 'text', 'text': t.text},
            for (final c in t.toolCalls)
              {'type': 'tool_use', 'id': c.id, 'name': c.name, 'input': c.arguments},
          ]);
          break;
        case AiRole.tool:
          add('user', [
            {
              'type': 'tool_result',
              'tool_use_id': t.toolCallId ?? '',
              'content': t.text,
            }
          ]);
          break;
      }
    }

    return {
      'model': r.model,
      'max_tokens': r.maxTokens ?? 4096,
      if (system.isNotEmpty) 'system': system.toString(),
      'messages': messages,
      if (r.hasTools)
        'tools': [
          for (final t in r.tools!)
            {
              'name': (t['function'] as Map)['name'],
              'description': (t['function'] as Map)['description'] ?? '',
              'input_schema': (t['function'] as Map)['parameters'] ??
                  {'type': 'object', 'properties': <String, dynamic>{}},
            }
        ],
      if (r.stream) 'stream': true,
    };
  }

  @override
  WireParser newParser({String provider = '', String model = ''}) =>
      AnthropicParser(provider: provider, model: model);
}

class _Block {
  String type = '';
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
  Map<String, dynamic>? fullInput;
}

class AnthropicParser implements WireParser {
  final String provider;
  final String model;
  AnthropicParser({this.provider = '', this.model = ''});

  final StringBuffer _text = StringBuffer();
  final Map<int, _Block> _blocks = {};
  String? _stop;
  int? _in;
  int? _out;

  @override
  String addChunk(Map<String, dynamic> chunk) {
    final type = chunk['type'];

    if (type == 'error' || (type == null && chunk['error'] != null)) {
      throw AiErrorMapper.fromStreamErrorObject(chunk['error'],
          provider: provider, model: model);
    }

    // Non-streamed full message.
    if (type == 'message' && chunk['content'] is List) {
      _readUsage(chunk['usage']);
      if (chunk['stop_reason'] is String) _stop = chunk['stop_reason'] as String;
      var visible = '';
      var i = 0;
      for (final b in chunk['content'] as List) {
        if (b is Map) {
          if (b['type'] == 'text' && b['text'] is String) {
            _text.write(b['text']);
            visible += b['text'] as String;
          } else if (b['type'] == 'tool_use') {
            final blk = _Block()
              ..type = 'tool_use'
              ..id = (b['id'] ?? '').toString()
              ..name = (b['name'] ?? '').toString()
              ..fullInput = b['input'] is Map
                  ? (b['input'] as Map).cast<String, dynamic>()
                  : <String, dynamic>{};
            _blocks[i] = blk;
          }
        }
        i++;
      }
      return visible;
    }

    switch (type) {
      case 'message_start':
        final m = chunk['message'];
        if (m is Map) _readUsage(m['usage']);
        return '';
      case 'content_block_start':
        final idx = chunk['index'];
        final cb = chunk['content_block'];
        if (idx is int && cb is Map) {
          final blk = _Block()..type = (cb['type'] ?? '').toString();
          if (blk.type == 'tool_use') {
            blk.id = (cb['id'] ?? '').toString();
            blk.name = (cb['name'] ?? '').toString();
          }
          _blocks[idx] = blk;
        }
        return '';
      case 'content_block_delta':
        final idx = chunk['index'];
        final d = chunk['delta'];
        if (idx is int && d is Map) {
          if (d['type'] == 'text_delta' && d['text'] is String) {
            _text.write(d['text']);
            return d['text'] as String;
          }
          if (d['type'] == 'input_json_delta' && d['partial_json'] is String) {
            _blocks[idx]?.args.write(d['partial_json']);
          }
        }
        return '';
      case 'message_delta':
        final d = chunk['delta'];
        if (d is Map && d['stop_reason'] is String) _stop = d['stop_reason'] as String;
        _readUsage(chunk['usage']);
        return '';
      default:
        return '';
    }
  }

  void _readUsage(dynamic u) {
    if (u is Map) {
      if (u['input_tokens'] is int) _in = u['input_tokens'] as int;
      if (u['output_tokens'] is int) _out = u['output_tokens'] as int;
    }
  }

  @override
  WireResult finish() {
    final calls = <AiToolCall>[];
    final keys = _blocks.keys.toList()..sort();
    for (final k in keys) {
      final b = _blocks[k]!;
      if (b.type != 'tool_use' || b.name.isEmpty) continue;
      final args = b.fullInput ?? decodeArgs(b.args.toString());
      if (args == null) {
        throw AiError(AiErrorKind.malformed,
            provider: provider, model: model, detail: 'tool input is not valid JSON');
      }
      calls.add(AiToolCall(
        id: b.id.isNotEmpty ? b.id : 'toolu_${DateTime.now().microsecondsSinceEpoch}_$k',
        name: b.name,
        arguments: args,
      ));
    }
    return WireResult(
      text: _text.toString(),
      toolCalls: calls,
      finishReason: _stop,
      inputTokens: _in,
      outputTokens: _out,
    );
  }
}
