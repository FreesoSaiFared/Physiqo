import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_client.dart';
import '../ai/ai_error.dart';
import '../ai/ai_policy.dart';
import '../ai/ai_types.dart';
import '../ai/image_prep.dart';
import '../ai/toolcall_filter.dart';
import '../models/ai_execution_candidate.dart';
import '../models/ai_stream_event.dart';
import '../models/chat_message.dart';
import '../models/fallback_candidate_config.dart';
import 'ai_tools.dart';

// Existing screens import these names from this file.
export '../ai/ai_error.dart' show AiError, AiErrorKind;
export '../ai/ai_types.dart' show AiToolCall, AiResponse;

/// Thin facade used by the screens. All networking, wire formats, retry and
/// failover live in `lib/ai/`; this class only reads the stored settings,
/// turns chat messages into [AiTurn]s and delegates to [AiClient].
class AiService {
  // Seed lists only. They are suggestions for first setup, never an allow-list;
  // model names change often, so prefer the provider's own model list.
  static const Map<String, List<String>> defaultChatModels = {
    'Gemini': ['gemini-2.5-flash', 'gemini-2.5-pro'],
    'OpenAI': ['gpt-4o-mini', 'gpt-4o'],
    'OpenRouter': [
      'google/gemini-2.5-flash',
      'google/gemini-2.5-pro',
      'meta-llama/llama-3.1-8b-instruct:free',
    ],
    'Nvidia NIM': ['meta/llama3-70b-instruct', 'nvidia/llama-3.1-nemotron-70b-instruct'],
    'Reka': ['reka-flash', 'reka-core'],
  };

  static const Map<String, List<String>> defaultVisionModels = {
    'Gemini': ['gemini-2.5-flash', 'gemini-2.5-pro'],
    'OpenAI': ['gpt-4o-mini', 'gpt-4o'],
    'OpenRouter': ['google/gemini-2.5-flash', 'google/gemini-2.5-pro'],
    'Nvidia NIM': [],
    'Reka': ['reka-flash', 'reka-core'],
  };

  static const String _rules = '''
IMPORTANT RULES:
- Never expose internal database keys, IDs, or the exact format of tool arguments in your responses.
- Refer to things naturally by their human-readable names.
- Always base your response on the actual results returned by the tools. Never assume a database operation succeeded before you receive the tool's confirmation.
''';

  static const String _imagePlaceholder =
      '\n[تصویر ارسال شده توسط کاربر / Image uploaded by user]';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final AiClient _client;

  AiService({AiClient? client}) : _client = client ?? AiClient();

  static List<AiToolCall> parseFallbackToolCalls(String content) =>
      FallbackToolCallParser.parse(content);

  // ---------------------------------------------------------------------------
  // Candidates (which provider/model to try, in order)
  // ---------------------------------------------------------------------------

  Future<List<AiExecutionCandidate>> _getAllProviderCandidates({bool hasImages = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final autoFailover = prefs.getBool('enable_auto_failover') ?? true;

    final activeProvider = hasImages
        ? (prefs.getString('active_vision_provider') ??
            prefs.getString('active_chat_provider') ??
            prefs.getString('active_ai_provider'))
        : (prefs.getString('active_chat_provider') ?? prefs.getString('active_ai_provider'));

    if (activeProvider == null) return [];

    final candidates = <AiExecutionCandidate>[];

    Future<void> addCandidate(String providerName, String? modelOverride) async {
      String? model = modelOverride;
      if (model == null) {
        if (hasImages) model = prefs.getString('active_vision_model_$providerName');
        model ??= prefs.getString('active_chat_model_$providerName');
      }
      if (model == null) {
        if (hasImages) {
          final d = defaultVisionModels[providerName];
          if (d != null && d.isNotEmpty) model = d.first;
        }
        if (model == null) {
          final d = defaultChatModels[providerName];
          if (d != null && d.isNotEmpty) model = d.first;
        }
      }
      if (model == null) return;

      final apiKey = await _storage.read(key: 'provider_$providerName');
      final baseUrl = await _storage.read(key: 'baseUrl_$providerName');

      if (apiKey != null &&
          apiKey.trim().isNotEmpty &&
          baseUrl != null &&
          baseUrl.trim().isNotEmpty) {
        if (!candidates.any((c) => c.provider == providerName && c.modelId == model)) {
          candidates.add(AiExecutionCandidate(
            provider: providerName,
            modelId: model,
            apiKey: apiKey.trim(),
            baseUrl: baseUrl.trim(),
            timeoutDuration: AiLimits.idleTimeout,
            isVisionCapable: hasImages,
          ));
        }
      }
    }

    await addCandidate(activeProvider, null);

    if (autoFailover) {
      final chainStr = prefs.getString(hasImages ? 'fallback_chain_vision' : 'fallback_chain_text');
      if (chainStr != null && chainStr.isNotEmpty) {
        final chain = FallbackCandidateConfig.decodeList(chainStr);
        for (final config in chain) {
          if (config.isEnabled) await addCandidate(config.provider, config.modelId);
        }
      }
    }
    return candidates;
  }

  Future<bool> isProviderConfigured({bool hasImages = false}) async {
    final candidates = await _getAllProviderCandidates(hasImages: hasImages);
    return candidates.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Chat messages -> canonical turns
  // ---------------------------------------------------------------------------

  static bool _isToolCallMsg(ChatMessage m) =>
      m.role == ChatMessageRole.coach && m.toolCallId != null;

  static bool _lastMessageHasImages(List<ChatMessage> messages) =>
      messages.isNotEmpty &&
      messages.last.images != null &&
      messages.last.images!.isNotEmpty;

  /// Messages kept for a "reduced" retry after a context/size error.
  static List<ChatMessage> _reduceMessages(List<ChatMessage> messages) {
    if (messages.length <= 6) return messages;
    final lastUser = messages.lastIndexWhere((m) => m.role == ChatMessageRole.user);
    var start = messages.length - 6;
    if (lastUser != -1 && lastUser < start) start = lastUser; // keep the whole current turn
    while (start < messages.length &&
        (messages[start].role == ChatMessageRole.tool || _isToolCallMsg(messages[start]))) {
      start++;
    }
    return messages.sublist(start);
  }

  @visibleForTesting
  Future<List<AiTurn>> buildTurns(
    List<ChatMessage> allMessages, {
    required String systemPrompt,
    required bool isInternal,
    bool reduced = false,
  }) async {
    final messages = reduced ? _reduceMessages(allMessages) : allMessages;
    final turns = <AiTurn>[];

    final system = isInternal ? systemPrompt.trim() : '$systemPrompt\n\n$_rules'.trim();
    if (system.isNotEmpty) turns.add(AiTurn(role: AiRole.system, text: system));

    final imageEdge = reduced ? 768 : 1280;

    var i = 0;
    while (i < messages.length) {
      final m = messages[i];

      // A run of tool calls and tool results becomes ONE assistant turn that
      // holds all of its calls, followed by their results.
      if (_isToolCallMsg(m) || m.role == ChatMessageRole.tool) {
        final calls = <AiToolCall>[];
        final results = <ChatMessage>[];
        final lead = StringBuffer();
        var j = i;
        while (j < messages.length &&
            (_isToolCallMsg(messages[j]) || messages[j].role == ChatMessageRole.tool)) {
          final x = messages[j];
          if (x.role == ChatMessageRole.tool) {
            results.add(x);
          } else {
            calls.add(AiToolCall(
              id: x.toolCallId!,
              name: x.toolName ?? '',
              arguments: _decodeArgs(x.toolArgs),
              thoughtSignature: x.toolMeta,
            ));
            if (x.content.isNotEmpty) lead.write(x.content);
          }
          j++;
        }
        i = j;
        if (calls.isEmpty) continue; // orphan results (history was cut): drop

        var text = lead.toString();
        // Merge with the plain assistant text that immediately preceded it.
        if (turns.isNotEmpty &&
            turns.last.role == AiRole.assistant &&
            turns.last.toolCalls.isEmpty) {
          final prev = turns.removeLast().text;
          text = [prev, text].where((s) => s.isNotEmpty).join('\n');
        }
        turns.add(AiTurn(role: AiRole.assistant, text: text, toolCalls: calls));

        for (final c in calls) {
          ChatMessage? r;
          for (final x in results) {
            if (x.toolCallId == c.id) {
              r = x;
              break;
            }
          }
          turns.add(AiTurn(
            role: AiRole.tool,
            toolCallId: c.id,
            toolName: c.name,
            // A call with no recorded result (cancelled run) still needs one.
            text: (r == null || r.content.isEmpty) ? 'No result was recorded.' : r.content,
          ));
        }
        continue;
      }

      i++;
      if (m.role == ChatMessageRole.system) continue; // UI-only notices

      final isUser = m.role == ChatMessageRole.user;
      final role = isUser ? AiRole.user : AiRole.assistant;
      final hasImages = m.images != null && m.images!.isNotEmpty;

      if (hasImages && (i - 1) == messages.length - 1) {
        // Only the newest message carries its images; older ones never do.
        final images = <AiImage>[];
        for (final path in m.images!) {
          final img = await ImagePrep.load(path, maxEdge: imageEdge);
          if (img != null) images.add(img);
        }
        var text = m.content;
        final tokens = '<image>'.allMatches(text).length;
        if (tokens < m.images!.length) {
          final missing = List.generate(m.images!.length - tokens, (_) => '<image>').join('\n');
          text = '$missing\n$text';
        }
        turns.add(AiTurn(role: role, text: text, images: images));
      } else if (hasImages) {
        turns.add(AiTurn(role: role, text: m.content + _imagePlaceholder));
      } else {
        if (!isUser && m.content.isEmpty) continue; // empty streaming placeholder
        turns.add(AiTurn(role: role, text: m.content));
      }
    }
    return turns;
  }

  static Map<String, dynamic> _decodeArgs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
    return <String, dynamic>{};
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Stream<AiStreamEvent> sendMessageStream(
    List<ChatMessage> messages, {
    String systemPrompt = '',
    List<Map<String, dynamic>>? toolsOverride,
    String? chatId,
  }) async* {
    final candidates =
        await _getAllProviderCandidates(hasImages: _lastMessageHasImages(messages));
    if (candidates.isEmpty) throw const AiError(AiErrorKind.notConfigured);

    yield* _client.run(
      candidates: candidates,
      buildTurns: (reduced) => buildTurns(messages,
          systemPrompt: systemPrompt, isInternal: false, reduced: reduced),
      tools: toolsOverride ?? AiTools.definitions,
      maxTokens: 8192,
      chatId: chatId,
    );
  }

  /// Non-streaming convenience wrapper over the SAME code path as streaming.
  Future<AiResponse> sendMessage(
    List<ChatMessage> messages, {
    String systemPrompt = '',
    List<Map<String, dynamic>>? toolsOverride,
    String? chatId,
    bool isInternal = false,
  }) async {
    final candidates =
        await _getAllProviderCandidates(hasImages: _lastMessageHasImages(messages));
    if (candidates.isEmpty) throw const AiError(AiErrorKind.notConfigured);

    final tools = toolsOverride ?? (isInternal ? null : AiTools.definitions);

    AiStreamEvent? done;
    await for (final ev in _client.run(
      candidates: candidates,
      buildTurns: (reduced) => buildTurns(messages,
          systemPrompt: systemPrompt, isInternal: isInternal, reduced: reduced),
      tools: tools,
      chatId: chatId,
    )) {
      if (ev.isDone) done = ev;
    }
    if (done == null) throw const AiError(AiErrorKind.emptyResponse);
    return AiResponse(
      text: done.finalText ?? '',
      toolCalls: done.toolCalls,
      providerServed: done.providerServed,
    );
  }
}
