import 'ai_error.dart';
import 'ai_types.dart';
import 'wire.dart';

/// Google Gemini native `generateContent` API.
class GeminiWire extends LlmWire {
  const GeminiWire();

  @override
  String get id => 'gemini';

  /// True when [baseUrl] or [providerName] identifies Gemini.
  static bool matches(String baseUrl, String providerName) =>
      baseUrl.contains('generativelanguage.googleapis.com') ||
      providerName.toLowerCase() == 'gemini';

  @override
  String normalizeBaseUrl(String baseUrl) {
    var b = super.normalizeBaseUrl(baseUrl);
    // The OpenAI-compat suffix is not valid for the native API.
    if (b.endsWith('/openai')) b = b.substring(0, b.length - '/openai'.length);
    return b;
  }

  @override
  Uri buildUrl(String baseUrl, String model, {required bool stream}) {
    final m = model.startsWith('models/') ? model.substring('models/'.length) : model;
    final b = normalizeBaseUrl(baseUrl);
    return stream
        ? Uri.parse('$b/models/$m:streamGenerateContent?alt=sse')
        : Uri.parse('$b/models/$m:generateContent');
  }

  /// The key travels ONLY in this header, never in the URL.
  @override
  Map<String, String> buildHeaders(String apiKey) => {
        'Content-Type': 'application/json; charset=utf-8',
        'x-goog-api-key': apiKey,
      };

  @override
  Map<String, dynamic> buildBody(WireRequest r, {String baseUrl = ''}) {
    final contents = <Map<String, dynamic>>[];
    Map<String, dynamic>? systemInstruction;

    void addContent(String role, List<Map<String, dynamic>> parts) {
      if (parts.isEmpty) return;
      if (contents.isNotEmpty && contents.last['role'] == role) {
        (contents.last['parts'] as List).addAll(parts);
      } else {
        contents.add({'role': role, 'parts': parts});
      }
    }

    // [verify] Gemini 3 enforces thought signatures on function calls. When a
    // call has none (history from another provider) Google documents a
    // placeholder value; confirm against current docs before relying on it.
    final needsSignature = r.model.contains('gemini-3');

    for (final t in r.turns) {
      switch (t.role) {
        case AiRole.system:
          if (t.text.isNotEmpty) {
            systemInstruction = {
              'parts': [
                {'text': t.text}
              ]
            };
          }
          break;
        case AiRole.user:
          final parts = <Map<String, dynamic>>[];
          for (final img in t.images) {
            parts.add({
              'inlineData': {'mimeType': img.mime, 'data': img.base64}
            });
          }
          if (t.text.isNotEmpty) parts.add({'text': t.text});
          addContent('user', parts);
          break;
        case AiRole.assistant:
          final parts = <Map<String, dynamic>>[];
          if (t.text.isNotEmpty) parts.add({'text': t.text});
          for (final c in t.toolCalls) {
            final sig = c.thoughtSignature ??
                (needsSignature ? 'skip_thought_signature_validator' : null);
            parts.add({
              'functionCall': {'name': c.name, 'args': c.arguments},
              if (sig != null) 'thoughtSignature': sig,
            });
          }
          addContent('model', parts);
          break;
        case AiRole.tool:
          addContent('user', [
            {
              'functionResponse': {
                'name': t.toolName ?? 'unknown_tool',
                'response': _responseObject(t.text),
              }
            }
          ]);
          break;
      }
    }

    return {
      'contents': contents,
      if (systemInstruction != null) 'systemInstruction': systemInstruction,
      if (r.hasTools)
        'tools': [
          {
            'functionDeclarations': [for (final t in r.tools!) t['function']]
          }
        ],
      // thinkingConfig is intentionally NOT sent: the default is dynamic
      // thinking on models that support it, and sending it to models that do
      // not (Gemma, older families) is rejected with HTTP 400.
    };
  }

  static Map<String, dynamic> _responseObject(String content) {
    final decoded = decodeArgs(content);
    // decodeArgs returns {} for blank text and null for non-object JSON.
    if (decoded != null && content.trim().isNotEmpty) return decoded;
    return {'result': content};
  }

  @override
  WireParser newParser({String provider = '', String model = ''}) =>
      GeminiParser(provider: provider, model: model);
}

class GeminiParser implements WireParser {
  final String provider;
  final String model;
  GeminiParser({this.provider = '', this.model = ''});

  final StringBuffer _text = StringBuffer();
  final List<AiToolCall> _calls = [];
  String? _finish;
  String? _blockReason;
  int? _in;
  int? _out;
  int _n = 0;

  static const Set<String> _blockedFinish = {
    'SAFETY',
    'RECITATION',
    'BLOCKLIST',
    'PROHIBITED_CONTENT',
    'SPII',
    'IMAGE_SAFETY',
  };

  @override
  String addChunk(Map<String, dynamic> chunk) {
    if (chunk['error'] != null) {
      throw AiErrorMapper.fromStreamErrorObject(chunk['error'],
          provider: provider, model: model);
    }
    final fb = chunk['promptFeedback'];
    if (fb is Map && fb['blockReason'] is String) {
      _blockReason = fb['blockReason'] as String;
    }
    final um = chunk['usageMetadata'];
    if (um is Map) {
      final i = um['promptTokenCount'];
      final o = um['candidatesTokenCount'];
      if (i is int) _in = i;
      if (o is int) _out = o;
    }

    final cands = chunk['candidates'];
    if (cands is! List || cands.isEmpty) return '';
    final cand = cands[0];
    if (cand is! Map) return '';
    final fr = cand['finishReason'];
    if (fr is String) _finish = fr;

    final content = cand['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List) return '';

    var visible = '';
    for (final part in parts) {
      if (part is! Map) continue;
      final isThought = part['thought'] == true;
      final text = part['text'];
      if (text is String && text.isNotEmpty && !isThought) {
        _text.write(text);
        visible += text;
      }
      final fc = part['functionCall'];
      if (fc is Map && fc['name'] is String) {
        _n++;
        final args = fc['args'];
        final sig = part['thoughtSignature'];
        _calls.add(AiToolCall(
          // Unique per call even when the same tool is called twice.
          id: 'call_${DateTime.now().microsecondsSinceEpoch}_$_n',
          name: fc['name'] as String,
          arguments: args is Map ? args.cast<String, dynamic>() : <String, dynamic>{},
          thoughtSignature: sig is String ? sig : null,
        ));
      }
    }
    return visible;
  }

  @override
  WireResult finish() {
    final text = _text.toString();
    if (text.trim().isEmpty && _calls.isEmpty) {
      if (_blockReason != null || (_finish != null && _blockedFinish.contains(_finish))) {
        throw AiError(AiErrorKind.contentBlocked,
            provider: provider, model: model, detail: _blockReason ?? _finish);
      }
      if (_finish == 'MALFORMED_FUNCTION_CALL') {
        throw AiError(AiErrorKind.malformed,
            provider: provider, model: model, detail: _finish);
      }
    }
    return WireResult(
      text: text,
      toolCalls: List.unmodifiable(_calls),
      finishReason: _finish,
      inputTokens: _in,
      outputTokens: _out,
    );
  }
}
