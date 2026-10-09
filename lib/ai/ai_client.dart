import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/ai_execution_candidate.dart';
import '../models/ai_stream_event.dart';
import '../services/ai_logger.dart';
import 'ai_error.dart';
import 'ai_policy.dart';
import 'ai_types.dart';
import 'anthropic_wire.dart';
import 'gemini_wire.dart';
import 'openai_wire.dart';
import 'sse.dart';
import 'toolcall_filter.dart';
import 'wire.dart';

/// The single entry point screens use to talk to a model.
///
/// Responsibilities: pick the right wire format, send, stream true deltas,
/// classify every failure as an [AiError], and apply [AiRetryPolicy] with a
/// hard cap of [AiLimits.maxHttpCalls] HTTP calls per user message.
class AiClient {
  final http.Client _http;
  final Future<void> Function(Duration) _delay;
  final Duration firstByteTimeout;
  final Duration firstByteTimeoutThinking;
  final Duration idleTimeout;

  /// Number of HTTP calls made by the most recent [run] (for tests / logs).
  int lastRunHttpCalls = 0;

  /// provider|model pairs that rejected tools; they are sent tool-less from
  /// then on (until the app restarts).
  static final Set<String> _noToolsModels = <String>{};

  AiClient({
    http.Client? httpClient,
    Future<void> Function(Duration)? delay,
    this.firstByteTimeout = AiLimits.firstByteTimeout,
    this.firstByteTimeoutThinking = AiLimits.firstByteTimeoutThinking,
    this.idleTimeout = AiLimits.idleTimeout,
  })  : _http = httpClient ?? _defaultHttpClient(),
        _delay = delay ?? Future<void>.delayed;

  static http.Client _defaultHttpClient() {
    final inner = HttpClient()..connectionTimeout = AiLimits.connectTimeout;
    return IOClient(inner);
  }

  static void resetLearnedCapabilities() => _noToolsModels.clear();

  static String _key(AiExecutionCandidate c) => '${c.provider}|${c.modelId}';

  static LlmWire wireFor(AiExecutionCandidate c) {
    final base = c.baseUrl ?? '';
    if (GeminiWire.matches(base, c.provider)) return const GeminiWire();
    if (AnthropicWire.matches(base, c.provider)) return const AnthropicWire();
    return const OpenAiWire();
  }

  /// Models that think before answering need a longer first-byte timeout.
  static bool isThinkingModel(String model) {
    final m = model.toLowerCase();
    return m.contains('gemini-2.5') ||
        m.contains('gemini-3') ||
        m.contains('thinking') ||
        m.contains('reason') ||
        m.contains('deepseek-r1') ||
        m.contains('-r1') ||
        RegExp(r'(^|/)o\d').hasMatch(m) ||
        m.contains('gpt-5');
  }

  static bool isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h.endsWith('.local')) return true;
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
    if (m == null) return false;
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    if (a == 127 || a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  /// Runs one user message to completion: attempts, retries and failover.
  ///
  /// [buildTurns] is called per attempt; `reduced == true` asks for a smaller
  /// request (less history, smaller images) after a context/size error.
  Stream<AiStreamEvent> run({
    required List<AiExecutionCandidate> candidates,
    required Future<List<AiTurn>> Function(bool reduced) buildTurns,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
    String? chatId,
  }) async* {
    lastRunHttpCalls = 0;
    if (candidates.isEmpty) {
      throw const AiError(AiErrorKind.notConfigured);
    }

    final budget = AiCallBudget();
    AiError? firstError;
    AiError? lastError;
    final skippedProviders = <String>{};

    for (final cand in candidates) {
      if (skippedProviders.contains(cand.provider)) continue;

      var attempt = 0;
      var toolsOn = tools != null && tools.isNotEmpty && !_noToolsModels.contains(_key(cand));
      var reduced = false;

      while (true) {
        if (!budget.tryConsume()) {
          throw (firstError ?? lastError ?? const AiError(AiErrorKind.network));
        }
        lastRunHttpCalls = budget.used;
        attempt++;

        var emitted = false;
        try {
          final turns = await buildTurns(reduced);
          final req = WireRequest(
            model: cand.modelId,
            turns: turns,
            tools: toolsOn ? tools : null,
            stream: true,
            maxTokens: maxTokens,
          );
          await for (final ev in _attempt(cand, req, chatId)) {
            if (ev.deltaText.isNotEmpty) emitted = true;
            yield ev;
          }
          return; // success
        } catch (e) {
          final err = AiErrorMapper.fromException(e,
              provider: cand.provider, model: cand.modelId);
          firstError ??= err;
          lastError = err;
          AiLogger.instance.addLog(
            requestPayload: {'provider': cand.provider, 'model': cand.modelId},
            responseRaw: '',
            latencyMs: 0,
            error: '${err.toString()} ${err.detail ?? ''}',
            chatId: chatId,
          );

          final decision = AiRetryPolicy.decide(
            err,
            attempt: attempt,
            toolsEnabled: toolsOn,
            reducedAlready: reduced,
            jitterMs: 0,
          );

          if (decision.action == AiAction.abort) throw err;

          // Anything already shown belongs to a failed attempt.
          if (emitted) yield AiStreamEvent(reset: true);

          switch (decision.action) {
            case AiAction.retrySame:
              if (decision.delay > Duration.zero) await _delay(decision.delay);
              continue;
            case AiAction.retryWithoutTools:
              toolsOn = false;
              _noToolsModels.add(_key(cand));
              continue;
            case AiAction.retryReduced:
              reduced = true;
              continue;
            case AiAction.failoverSkipProvider:
              skippedProviders.add(cand.provider);
              break;
            case AiAction.failover:
            case AiAction.abort:
              break;
          }
          break; // leave the while loop -> next candidate
        }
      }
    }

    throw (firstError ?? lastError ?? const AiError(AiErrorKind.network));
  }

  /// Exactly one HTTP call, no retry and no failover. Used by diagnostics.
  /// Returns the final (done) event or throws an [AiError].
  Future<AiStreamEvent> attemptOnce(
    AiExecutionCandidate c,
    List<AiTurn> turns, {
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
  }) async {
    AiStreamEvent? done;
    try {
      await for (final ev in _attempt(
        c,
        WireRequest(
            model: c.modelId, turns: turns, tools: tools, stream: true, maxTokens: maxTokens),
        null,
      )) {
        if (ev.isDone) done = ev;
      }
    } catch (e) {
      throw AiErrorMapper.fromException(e, provider: c.provider, model: c.modelId);
    }
    if (done == null) {
      throw AiError(AiErrorKind.emptyResponse, provider: c.provider, model: c.modelId);
    }
    return done;
  }

  /// One HTTP call against one candidate. Throws [AiError] / transport errors.
  Stream<AiStreamEvent> _attempt(
    AiExecutionCandidate c,
    WireRequest req,
    String? chatId,
  ) async* {
    final wire = wireFor(c);
    final base = c.baseUrl ?? '';
    final apiKey = c.apiKey ?? '';
    final url = wire.buildUrl(base, c.modelId, stream: true);

    if (url.scheme != 'https' && !(url.scheme == 'http' && isPrivateHost(url.host))) {
      throw AiError(AiErrorKind.badRequest,
          provider: c.provider,
          model: c.modelId,
          detail: 'Only https (or http for local/LAN hosts) is allowed.');
    }

    final body = wire.buildBody(req, baseUrl: base);
    final headers = <String, String>{
      ...wire.buildHeaders(apiKey),
      if (wire is OpenAiWire) ...OpenAiWire.extraHeaders(base),
    };
    final request = http.Request('POST', url)
      ..headers.addAll(headers)
      ..body = jsonEncode(body);

    final sw = Stopwatch()..start();
    final firstByte =
        isThinkingModel(c.modelId) ? firstByteTimeoutThinking : firstByteTimeout;

    final http.StreamedResponse resp;
    try {
      resp = await _http.send(request).timeout(firstByte);
    } catch (e) {
      throw AiErrorMapper.fromException(e, provider: c.provider, model: c.modelId);
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      String errBody = '';
      try {
        errBody = await resp.stream.bytesToString().timeout(const Duration(seconds: 10));
      } catch (_) {}
      throw AiErrorMapper.fromHttp(
        status: resp.statusCode,
        body: errBody,
        provider: c.provider,
        model: c.modelId,
        retryAfterHeader: resp.headers['retry-after'],
        apiKey: apiKey,
      );
    }

    final parser = wire.newParser(provider: c.provider, model: c.modelId);
    final filter = ToolCallTextFilter();
    final raw = StringBuffer();
    var sawData = false;
    final contentType = (resp.headers['content-type'] ?? '').toLowerCase();

    if (contentType.contains('application/json')) {
      // Server ignored streaming and returned one JSON document.
      String bodyText;
      try {
        bodyText = await resp.stream.bytesToString().timeout(firstByte);
      } catch (e) {
        throw AiErrorMapper.fromException(e, provider: c.provider, model: c.modelId);
      }
      raw.write(bodyText);
      final obj = _decodeObject(bodyText);
      if (obj == null) {
        throw AiError(AiErrorKind.malformed, provider: c.provider, model: c.modelId);
      }
      final delta = parser.addChunk(obj);
      if (delta.isNotEmpty) {
        final vis = filter.feed(delta);
        if (vis.isNotEmpty) yield AiStreamEvent(deltaText: vis, providerServed: c.provider);
      }
      sawData = true;
    } else {
      final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      final stray = StringBuffer();
      await for (final line in _withTimeouts(lines, firstByte, idleTimeout)) {
        if (raw.length < 40000) raw.writeln(line);
        final s = SseLine.parse(line);
        if (s.isDone) break;
        if (s.data == null) {
          final t = line.trim();
          if (t.isNotEmpty &&
              !t.startsWith(':') &&
              !t.startsWith('event:') &&
              !t.startsWith('id:') &&
              !t.startsWith('retry:') &&
              stray.length < 65536) {
            stray.writeln(line);
          }
          continue;
        }
        final chunk = _decodeObject(s.data!);
        if (chunk == null) continue; // unreadable chunk: skip, never crash
        sawData = true;
        final delta = parser.addChunk(chunk);
        if (delta.isNotEmpty) {
          final vis = filter.feed(delta);
          if (vis.isNotEmpty) yield AiStreamEvent(deltaText: vis, providerServed: c.provider);
        }
      }

      if (!sawData && stray.isNotEmpty) {
        // Some servers answer a streaming request with a plain JSON body or
        // an error object without any `data:` prefix.
        final obj = _decodeObject(stray.toString());
        if (obj != null) {
          final delta = parser.addChunk(obj);
          sawData = true;
          if (delta.isNotEmpty) {
            final vis = filter.feed(delta);
            if (vis.isNotEmpty) {
              yield AiStreamEvent(deltaText: vis, providerServed: c.provider);
            }
          }
        }
      }
    }

    final result = parser.finish();
    sw.stop();

    var text = result.text;
    final calls = List<AiToolCall>.from(result.toolCalls);
    if (calls.isEmpty || text.contains(ToolCallTextFilter.openTag)) {
      final ex = ToolCallText.extract(text, FallbackToolCallParser.parse);
      text = ex.text;
      calls.addAll(ex.calls);
    }

    AiLogger.instance.addLog(
      requestPayload: body,
      responseRaw: raw.toString(),
      latencyMs: sw.elapsedMilliseconds,
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
      chatId: chatId,
    );

    if (text.trim().isEmpty && calls.isEmpty) {
      throw AiError(AiErrorKind.emptyResponse,
          provider: c.provider,
          model: c.modelId,
          detail: sawData ? 'no content' : 'no data received');
    }

    yield AiStreamEvent(
      isDone: true,
      finalText: text,
      toolCalls: calls.isEmpty ? null : calls,
      providerServed: c.provider,
    );
  }

  static Map<String, dynamic>? _decodeObject(String s) {
    try {
      final d = jsonDecode(s);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  /// Per-event timeouts: [first] for the first line, [idle] between lines.
  static Stream<String> _withTimeouts(
    Stream<String> source,
    Duration first,
    Duration idle,
  ) async* {
    final it = StreamIterator<String>(source);
    var isFirst = true;
    try {
      while (true) {
        final has = await it.moveNext().timeout(isFirst ? first : idle);
        if (!has) break;
        isFirst = false;
        yield it.current;
      }
    } finally {
      try {
        await it.cancel();
      } catch (_) {}
    }
  }
}
