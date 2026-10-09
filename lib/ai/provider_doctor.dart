import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_execution_candidate.dart';
import 'ai_client.dart';
import 'ai_error.dart';
import 'ai_types.dart';
import 'anthropic_wire.dart';
import 'gemini_wire.dart';

class DoctorStep {
  final String id; // url | models | chat | tools | vision
  final bool ok;
  final bool skipped;
  final AiErrorKind? errorKind;

  /// Plain-language result for the user (English; UI may localize by [id]).
  final String message;

  const DoctorStep(this.id, {required this.ok, this.skipped = false, this.errorKind, this.message = ''});
}

class DoctorModel {
  final String id;
  final bool? supportsTools; // null = unknown (probe it)
  final bool? supportsVision;
  const DoctorModel(this.id, {this.supportsTools, this.supportsVision});
}

class DoctorReport {
  final List<DoctorStep> steps;
  final List<DoctorModel> models;
  final bool chatOk;
  final bool toolsOk;
  final bool visionOk;

  const DoctorReport({
    required this.steps,
    required this.models,
    required this.chatOk,
    required this.toolsOk,
    required this.visionOk,
  });

  /// True when a real chat call succeeded. This is the only thing that proves
  /// the provider works (a model list alone does not).
  bool get usable => chatOk;
}

/// Replaces the old "Test connection" buttons. Nothing here changes stored
/// settings; the caller decides what to do with the report.
///
/// [verify] Model-list metadata fields (Gemini `supportedGenerationMethods`,
/// OpenRouter `supported_parameters` / `architecture.input_modalities`) were
/// written from memory of the docs and must be checked against real responses.
class ProviderDoctor {
  final http.Client _http;
  final AiClient _client;

  ProviderDoctor({http.Client? httpClient, AiClient? client})
      : _http = httpClient ?? http.Client(),
        _client = client ?? AiClient();

  static const String _tinyPng =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  static final List<Map<String, dynamic>> _pingTool = [
    {
      'type': 'function',
      'function': {
        'name': 'ping',
        'description': 'Health check. Call this function.',
        'parameters': {
          'type': 'object',
          'properties': {
            'note': {'type': 'string', 'description': 'Any short text'}
          },
        },
      },
    }
  ];

  static bool looksLikeChatModel(String id) {
    final m = id.toLowerCase();
    const bad = [
      'embed', 'whisper', 'tts', 'dall-e', 'moderation', 'rerank', 'imagen',
      'image-generation', 'audio', 'transcribe', 'speech', 'veo', 'aqa',
    ];
    for (final b in bad) {
      if (m.contains(b)) return false;
    }
    return true;
  }

  Future<DoctorReport> run(
    AiExecutionCandidate c, {
    void Function(DoctorStep step)? onStep,
  }) async {
    final steps = <DoctorStep>[];
    void add(DoctorStep s) {
      steps.add(s);
      onStep?.call(s);
    }

    // 1. URL
    final base = (c.baseUrl ?? '').trim();
    final uri = Uri.tryParse(base);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      add(const DoctorStep('url',
          ok: false, errorKind: AiErrorKind.badRequest, message: 'The base URL is not valid.'));
      return _finish(steps, const []);
    }
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && AiClient.isPrivateHost(uri.host))) {
      add(const DoctorStep('url',
          ok: false,
          errorKind: AiErrorKind.badRequest,
          message: 'Use https. Plain http is only allowed for local or LAN servers.'));
      return _finish(steps, const []);
    }
    add(const DoctorStep('url', ok: true, message: 'Address looks fine.'));

    // 2. Auth + models (with pagination)
    List<DoctorModel> models = const [];
    try {
      models = await listModels(c);
      add(DoctorStep('models',
          ok: true, message: '${models.length} chat-capable models found.'));
    } on AiError catch (e) {
      if (e.statusCode == 404) {
        // Some servers have no /models route; the chat probe decides.
        add(const DoctorStep('models',
            ok: true, skipped: true, message: 'This server has no model list; skipped.'));
      } else {
        add(DoctorStep('models', ok: false, errorKind: e.kind, message: e.userMessage(isFa: false)));
        if (e.kind == AiErrorKind.auth || e.kind == AiErrorKind.network) {
          return _finish(steps, models);
        }
      }
    }

    // 3. Real chat call
    var chatOk = false;
    try {
      final tokens = AiClient.isThinkingModel(c.modelId) ? 1024 : 64;
      final ev = await _client.attemptOnce(
        c,
        const [AiTurn(role: AiRole.user, text: 'Reply with the single word OK.')],
        maxTokens: tokens,
      );
      chatOk = (ev.finalText ?? '').trim().isNotEmpty;
      add(DoctorStep('chat',
          ok: chatOk, message: chatOk ? 'The model answered.' : 'The model answered with nothing.'));
    } on AiError catch (e) {
      add(DoctorStep('chat', ok: false, errorKind: e.kind, message: e.userMessage(isFa: false)));
    }
    if (!chatOk) {
      add(const DoctorStep('tools', ok: false, skipped: true, message: 'Skipped: chat does not work.'));
      add(const DoctorStep('vision', ok: false, skipped: true, message: 'Skipped: chat does not work.'));
      return DoctorReport(steps: steps, models: models, chatOk: false, toolsOk: false, visionOk: false);
    }

    // 4. Tool probe
    var toolsOk = false;
    try {
      final ev = await _client.attemptOnce(
        c,
        const [
          AiTurn(role: AiRole.user, text: 'Call the ping function now with note "hi". Do not answer in text.')
        ],
        tools: _pingTool,
        maxTokens: AiClient.isThinkingModel(c.modelId) ? 1024 : 128,
      );
      toolsOk = (ev.toolCalls ?? const []).any((t) => t.name == 'ping');
      add(DoctorStep('tools',
          ok: toolsOk,
          message: toolsOk ? 'Tool calling works.' : 'The model ignored the tool.'));
    } on AiError catch (e) {
      add(DoctorStep('tools', ok: false, errorKind: e.kind, message: e.userMessage(isFa: false)));
    }

    // 5. Vision probe
    var visionOk = false;
    try {
      final ev = await _client.attemptOnce(
        c,
        const [
          AiTurn(
            role: AiRole.user,
            text: 'Reply with the single word OK.',
            images: [AiImage(mime: 'image/png', base64: _tinyPng)],
          )
        ],
        maxTokens: AiClient.isThinkingModel(c.modelId) ? 1024 : 64,
      );
      visionOk = (ev.finalText ?? '').trim().isNotEmpty;
      add(DoctorStep('vision',
          ok: visionOk, message: visionOk ? 'Image input works.' : 'No answer to the image.'));
    } on AiError catch (e) {
      add(DoctorStep('vision', ok: false, errorKind: e.kind, message: e.userMessage(isFa: false)));
    }

    return DoctorReport(
        steps: steps, models: models, chatOk: true, toolsOk: toolsOk, visionOk: visionOk);
  }

  DoctorReport _finish(List<DoctorStep> steps, List<DoctorModel> models) => DoctorReport(
        steps: steps,
        models: models,
        chatOk: false,
        toolsOk: false,
        visionOk: false,
      );

  /// Fetches ALL pages of the provider's model list and keeps chat models.
  Future<List<DoctorModel>> listModels(AiExecutionCandidate c) async {
    final wire = AiClient.wireFor(c);
    final base = wire.normalizeBaseUrl(c.baseUrl ?? '');
    final key = c.apiKey ?? '';
    final out = <DoctorModel>[];

    Future<Map<String, dynamic>> get(Uri url) async {
      final headers = wire.buildHeaders(key)..remove('Content-Type');
      http.Response r;
      try {
        r = await _http.get(url, headers: headers).timeout(const Duration(seconds: 20));
      } catch (e) {
        throw AiErrorMapper.fromException(e, provider: c.provider, model: c.modelId);
      }
      if (r.statusCode != 200) {
        throw AiErrorMapper.fromHttp(
          status: r.statusCode,
          body: r.body,
          provider: c.provider,
          model: c.modelId,
          retryAfterHeader: r.headers['retry-after'],
          apiKey: key,
        );
      }
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d is! Map) {
        throw AiError(AiErrorKind.malformed, provider: c.provider, model: c.modelId);
      }
      return d.cast<String, dynamic>();
    }

    if (wire is GeminiWire) {
      String? token;
      var pages = 0;
      do {
        final qp = <String, String>{'pageSize': '1000', if (token != null) 'pageToken': token};
        final d = await get(Uri.parse('$base/models').replace(queryParameters: qp));
        for (final m in (d['models'] as List? ?? const [])) {
          if (m is! Map) continue;
          final methods = (m['supportedGenerationMethods'] as List? ?? const []).map((e) => e.toString());
          if (!methods.contains('generateContent')) continue;
          final name = (m['name'] ?? '').toString();
          final id = name.startsWith('models/') ? name.substring(7) : name;
          if (id.isNotEmpty && looksLikeChatModel(id)) out.add(DoctorModel(id));
        }
        token = d['nextPageToken'] is String && (d['nextPageToken'] as String).isNotEmpty
            ? d['nextPageToken'] as String
            : null;
        pages++;
      } while (token != null && pages < 10);
      return out;
    }

    if (wire is AnthropicWire) {
      final d = await get(Uri.parse('$base/models?limit=1000'));
      for (final m in (d['data'] as List? ?? const [])) {
        if (m is Map && m['id'] != null) out.add(DoctorModel(m['id'].toString()));
      }
      return out;
    }

    final d = await get(Uri.parse('$base/models'));
    for (final m in (d['data'] as List? ?? const [])) {
      if (m is! Map || m['id'] == null) continue;
      final id = m['id'].toString();
      if (!looksLikeChatModel(id)) continue;
      bool? tools;
      bool? vision;
      final sp = m['supported_parameters'];
      if (sp is List) tools = sp.map((e) => e.toString()).contains('tools');
      final arch = m['architecture'];
      if (arch is Map && arch['input_modalities'] is List) {
        vision = (arch['input_modalities'] as List).map((e) => e.toString()).contains('image');
      }
      out.add(DoctorModel(id, supportsTools: tools, supportsVision: vision));
    }
    return out;
  }
}
