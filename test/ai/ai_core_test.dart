import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:physiqo/ai/ai_error.dart';
import 'package:physiqo/ai/ai_policy.dart';
import 'package:physiqo/ai/ai_types.dart';
import 'package:physiqo/ai/anthropic_wire.dart';
import 'package:physiqo/ai/gemini_wire.dart';
import 'package:physiqo/ai/openai_wire.dart';
import 'package:physiqo/ai/sse.dart';
import 'package:physiqo/ai/toolcall_filter.dart';

void main() {
  group('AiErrorMapper (bodies are shaped like real provider errors; re-capture before release)', () {
    AiErrorKind k(int s, [String b = '']) => AiErrorMapper.fromHttp(status: s, body: b).kind;

    test('status mapping', () {
      expect(k(401), AiErrorKind.auth);
      expect(k(403, 'forbidden'), AiErrorKind.auth);
      expect(k(404), AiErrorKind.modelNotFound);
      expect(k(413), AiErrorKind.payloadTooLarge);
      expect(k(429, 'slow down'), AiErrorKind.rateLimited);
      expect(k(429, '{"error":{"code":"insufficient_quota"}}'), AiErrorKind.quota);
      expect(k(500), AiErrorKind.server);
      expect(k(503), AiErrorKind.server);
    });

    test('400 bodies', () {
      expect(k(400, '{"error":{"message":"API key not valid. Please pass a valid API key."}}'),
          AiErrorKind.auth);
      expect(k(400, 'No endpoints found that support tool use'), AiErrorKind.toolsUnsupported);
      expect(k(400, '[] is too short - tools'), AiErrorKind.toolsUnsupported);
      expect(k(400, "This model's maximum context length is 8192 tokens"), AiErrorKind.contextTooLong);
      expect(k(400, 'model does not support image input'), AiErrorKind.visionUnsupported);
      expect(k(400, 'blocked by safety settings'), AiErrorKind.contentBlocked);
      expect(k(400, 'something else'), AiErrorKind.badRequest);
    });

    test('retry-after parsed', () {
      final e = AiErrorMapper.fromHttp(status: 429, body: '', retryAfterHeader: '7');
      expect(e.retryAfter, const Duration(seconds: 7));
    });

    test('errors and redaction never leak keys or bodies', () {
      final e = AiErrorMapper.fromHttp(
          status: 401, body: 'bad key sk-ABCDEFGHIJKLMNOPQRSTUVWX', provider: 'P', model: 'm');
      expect(e.toString().contains('sk-'), isFalse);
      expect(e.detail!.contains('sk-ABCDEF'), isFalse);
      expect(e.userMessage(isFa: false).contains('sk-'), isFalse);
    });
  });

  group('AiRetryPolicy', () {
    AiPolicyDecision d(AiErrorKind kind,
            {int attempt = 1, bool tools = true, bool reduced = false, Duration? ra}) =>
        AiRetryPolicy.decide(AiError(kind, retryAfter: ra),
            attempt: attempt, toolsEnabled: tools, reducedAlready: reduced);

    test('401 never retries and skips provider', () {
      expect(d(AiErrorKind.auth).action, AiAction.failoverSkipProvider);
    });
    test('404 never retries', () {
      expect(d(AiErrorKind.modelNotFound).action, AiAction.failover);
    });
    test('network: 2 retries with 1s/3s then failover', () {
      expect(d(AiErrorKind.network, attempt: 1).delay, const Duration(seconds: 1));
      expect(d(AiErrorKind.network, attempt: 2).delay, const Duration(seconds: 3));
      expect(d(AiErrorKind.network, attempt: 3).action, AiAction.failover);
    });
    test('429 honours Retry-After, one retry, capped at 20s', () {
      expect(d(AiErrorKind.rateLimited, ra: const Duration(seconds: 5)).delay,
          const Duration(seconds: 5));
      expect(d(AiErrorKind.rateLimited, ra: const Duration(seconds: 60)).action, AiAction.failover);
      expect(d(AiErrorKind.rateLimited, attempt: 2).action, AiAction.failover);
    });
    test('tools unsupported -> retry without tools once', () {
      expect(d(AiErrorKind.toolsUnsupported).action, AiAction.retryWithoutTools);
      expect(d(AiErrorKind.toolsUnsupported, tools: false).action, AiAction.failover);
    });
    test('context too long -> reduce once then failover', () {
      expect(d(AiErrorKind.contextTooLong).action, AiAction.retryReduced);
      expect(d(AiErrorKind.contextTooLong, reduced: true).action, AiAction.failover);
    });
    test('blocked content aborts', () {
      expect(d(AiErrorKind.contentBlocked).action, AiAction.abort);
    });
    test('budget caps at 6', () {
      final b = AiCallBudget();
      for (var i = 0; i < 6; i++) {
        expect(b.tryConsume(), isTrue);
      }
      expect(b.tryConsume(), isFalse);
    });
  });

  group('SSE', () {
    test('data with and without space, comments, done', () {
      expect(SseLine.parse('data: {"a":1}').data, '{"a":1}');
      expect(SseLine.parse('data:{"a":1}').data, '{"a":1}');
      expect(SseLine.parse(': keep-alive').data, isNull);
      expect(SseLine.parse('event: x').data, isNull);
      expect(SseLine.parse('data: [DONE]').isDone, isTrue);
    });
  });

  group('OpenAI wire', () {
    const wire = OpenAiWire();
    test('never sends an empty tools array; key only in header', () {
      final body = wire.buildBody(const WireRequest(
          model: 'm', turns: [AiTurn(role: AiRole.user, text: 'hi')], tools: []));
      expect(body.containsKey('tools'), isFalse);
      expect(wire.buildUrl('https://x.test/v1/', 'm', stream: true).toString(),
          'https://x.test/v1/chat/completions');
      expect(wire.buildHeaders('KEY')['Authorization'], 'Bearer KEY');
    });
    test('assistant turn holds all its tool calls', () {
      final body = wire.buildBody(WireRequest(model: 'm', turns: [
        AiTurn(role: AiRole.assistant, toolCalls: [
          AiToolCall(id: 'a', name: 'f', arguments: {'x': 1}),
          AiToolCall(id: 'b', name: 'g', arguments: {}),
        ]),
        const AiTurn(role: AiRole.tool, toolCallId: 'a', text: 'ok'),
        const AiTurn(role: AiRole.tool, toolCallId: 'b', text: 'ok'),
      ]));
      final msgs = body['messages'] as List;
      expect(msgs.length, 3);
      expect((msgs[0]['tool_calls'] as List).length, 2);
    });
    test('parallel calls without index are separated by id; continuation merges', () {
      final p = wire.newParser();
      p.addChunk({'choices': [{'delta': {'tool_calls': [{'id': 'c1', 'function': {'name': 'f', 'arguments': '{"a":'}}]}}]});
      p.addChunk({'choices': [{'delta': {'tool_calls': [{'function': {'arguments': '1}'}}]}}]});
      p.addChunk({'choices': [{'delta': {'tool_calls': [{'id': 'c2', 'function': {'name': 'g', 'arguments': '{}'}}]}}]});
      final r = p.finish();
      expect(r.toolCalls.map((c) => c.id), ['c1', 'c2']);
      expect(r.toolCalls[0].arguments, {'a': 1});
    });
    test('same index reused with different ids stays two calls', () {
      final p = wire.newParser();
      p.addChunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'f', 'arguments': '{}'}}]}}]});
      p.addChunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c2', 'function': {'name': 'g', 'arguments': '{}'}}]}}]});
      expect(p.finish().toolCalls.length, 2);
    });
    test('truncated tool arguments are malformed, not dropped', () {
      final p = wire.newParser();
      p.addChunk({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c', 'function': {'name': 'f', 'arguments': '{"a":'}}]}}]});
      expect(() => p.finish(), throwsA(isA<AiError>().having((e) => e.kind, 'kind', AiErrorKind.malformed)));
    });
    test('reasoning-only response is flagged', () {
      final p = wire.newParser();
      p.addChunk({'choices': [{'delta': {'reasoning_content': 'thinking'}}]});
      expect(p.finish().reasoningOnly, isTrue);
    });
    test('error object inside a 200 stream throws mapped error', () {
      final p = wire.newParser();
      expect(() => p.addChunk({'error': {'code': 429, 'message': 'rate'}}),
          throwsA(isA<AiError>().having((e) => e.kind, 'kind', AiErrorKind.rateLimited)));
    });
  });

  group('Gemini wire', () {
    const wire = GeminiWire();
    test('key only in header, never in URL; no thinkingConfig', () {
      final url = wire.buildUrl('https://g.test/v1beta/openai', 'models/gemini-2.5-flash', stream: true);
      expect(url.toString(), 'https://g.test/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse');
      expect(wire.buildHeaders('K')['x-goog-api-key'], 'K');
      final body = wire.buildBody(const WireRequest(
          model: 'gemini-2.5-flash', turns: [AiTurn(role: AiRole.user, text: 'hi')]));
      expect(jsonEncode(body).contains('thinkingConfig'), isFalse);
    });
    test('thought signature is echoed; duplicate tool names get unique ids', () {
      final p = wire.newParser();
      for (var i = 0; i < 2; i++) {
        p.addChunk({'candidates': [{'content': {'parts': [{'functionCall': {'name': 'f', 'args': {}}, 'thoughtSignature': 'sig$i'}]}}]});
      }
      final calls = p.finish().toolCalls;
      expect(calls[0].id == calls[1].id, isFalse);
      final body = wire.buildBody(WireRequest(model: 'gemini-2.5-flash', turns: [
        AiTurn(role: AiRole.assistant, toolCalls: calls),
        AiTurn(role: AiRole.tool, toolCallId: calls[0].id, toolName: 'f', text: '{"ok":true}'),
        AiTurn(role: AiRole.tool, toolCallId: calls[1].id, toolName: 'f', text: 'plain'),
      ]));
      final contents = body['contents'] as List;
      expect(contents.length, 2); // model turn + one merged user turn
      expect(((contents[0]['parts'] as List)[0] as Map)['thoughtSignature'], 'sig0');
      expect((contents[1]['parts'] as List).length, 2);
    });
    test('safety block becomes contentBlocked', () {
      final p = wire.newParser();
      p.addChunk({'promptFeedback': {'blockReason': 'SAFETY'}});
      expect(() => p.finish(), throwsA(isA<AiError>().having((e) => e.kind, 'kind', AiErrorKind.contentBlocked)));
    });
  });

  group('Anthropic wire', () {
    const wire = AnthropicWire();
    test('headers, tool_result merge, stream parse', () {
      expect(wire.buildHeaders('K')['x-api-key'], 'K');
      final body = wire.buildBody(WireRequest(model: 'm', tools: [
        {'type': 'function', 'function': {'name': 'f', 'description': 'd', 'parameters': {'type': 'object', 'properties': {}}}}
      ], turns: [
        const AiTurn(role: AiRole.system, text: 'sys'),
        const AiTurn(role: AiRole.user, text: 'hi'),
        AiTurn(role: AiRole.assistant, toolCalls: [AiToolCall(id: 't1', name: 'f', arguments: {})]),
        const AiTurn(role: AiRole.tool, toolCallId: 't1', text: 'r'),
      ]));
      expect(body['system'], 'sys');
      expect((body['messages'] as List).length, 3);
      expect((body['tools'] as List)[0]['input_schema'], isNotNull);

      final p = wire.newParser();
      p.addChunk({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'x', 'name': 'f'}});
      p.addChunk({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{"a":1}'}});
      expect(p.finish().toolCalls.single.arguments, {'a': 1});
    });
  });

  group('Tool-call text', () {
    test('filter hides <TOOLCALL> and partial tags', () {
      final f = ToolCallTextFilter();
      final out = StringBuffer()
        ..write(f.feed('Hello <TOOL'))
        ..write(f.feed('CALL>[{"name":"x"}]</TOOLCALL>'));
      expect(out.toString(), 'Hello ');
    });
    test('extract finds fallback calls', () {
      final r = ToolCallText.extract('Sure <TOOLCALL>{"name":"f","parameters":{"a":1}}</TOOLCALL>',
          FallbackToolCallParser.parse);
      expect(r.text, 'Sure');
      expect(r.calls.single.name, 'f');
    });
  });
}
