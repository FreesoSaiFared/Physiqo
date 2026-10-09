import 'package:flutter_test/flutter_test.dart';
import 'package:physiqo/ai/ai_client.dart';
import 'package:physiqo/ai/ai_error.dart';
import 'package:physiqo/ai/ai_types.dart';
import 'package:physiqo/models/ai_execution_candidate.dart';
import 'package:physiqo/models/ai_stream_event.dart';

import 'fake_server.dart';

const _turns = [AiTurn(role: AiRole.user, text: 'hi')];
final _tools = [
  {'type': 'function', 'function': {'name': 'f', 'description': 'd', 'parameters': {'type': 'object', 'properties': {'a': {'type': 'string'}}}}}
];

AiExecutionCandidate cand(String base, {String provider = 'P', String model = 'm'}) =>
    AiExecutionCandidate(
        provider: provider,
        modelId: model,
        apiKey: 'KEY12345',
        baseUrl: base,
        timeoutDuration: const Duration(seconds: 5),
        isVisionCapable: false);

Future<List<AiStreamEvent>> collect(AiClient c, List<AiExecutionCandidate> cs,
    {List<Map<String, dynamic>>? tools}) async {
  final out = <AiStreamEvent>[];
  await for (final e in c.run(candidates: cs, buildTurns: (_) async => _turns, tools: tools)) {
    out.add(e);
  }
  return out;
}

Future<AiError> failure(AiClient c, List<AiExecutionCandidate> cs) async {
  try {
    await collect(c, cs);
  } on AiError catch (e) {
    return e;
  }
  fail('expected AiError');
}

AiClient client() => AiClient(
    delay: (_) async {},
    firstByteTimeout: const Duration(milliseconds: 600),
    firstByteTimeoutThinking: const Duration(milliseconds: 600),
    idleTimeout: const Duration(milliseconds: 600));

void main() {
  late FakeServer s;
  setUp(() async => s = await FakeServer.start());
  tearDown(() async {
    AiClient.resetLearnedCapabilities();
    await s.stop();
  });

  String text(List<AiStreamEvent> ev) => ev.where((e) => !e.isDone).map((e) => e.deltaText).join();

  test('streams true deltas; split `data:` without space works', () async {
    s.script.add(FakeServer.sse([
      FakeServer.oaText('Hel'),
      FakeServer.oaText('lo').replaceFirst('data: ', 'data:'),
      ': ping',
    ]));
    final ev = await collect(client(), [cand(s.base)]);
    expect(text(ev), 'Hello');
    expect(ev.last.isDone, isTrue);
    expect(ev.last.finalText, 'Hello');
    expect(s.headers.first.value('authorization'), 'Bearer KEY12345');
  });

  test('two parallel tool calls without index', () async {
    s.script.add(FakeServer.sse([
      FakeServer.oaToolChunk(id: 'a', name: 'f', args: '{}'),
      FakeServer.oaToolChunk(id: 'b', name: 'f', args: '{}'),
    ]));
    final ev = await collect(client(), [cand(s.base)], tools: _tools);
    expect(ev.last.toolCalls!.map((c) => c.id), ['a', 'b']);
  });

  test('401: one call, no retry, error is auth', () async {
    s.script.add(FakeServer.status(401, '{"error":"bad key"}'));
    final e = await failure(client(), [cand(s.base)]);
    expect(e.kind, AiErrorKind.auth);
    expect(s.calls, 1);
  });

  test('401 on provider A skips its other models, B answers', () async {
    final b = await FakeServer.start();
    addTearDown(b.stop);
    s.script.add(FakeServer.status(401));
    b.script.add(FakeServer.sse([FakeServer.oaText('ok')]));
    final ev = await collect(client(),
        [cand(s.base, provider: 'A', model: 'a1'), cand(s.base, provider: 'A', model: 'a2'), cand(b.base, provider: 'B')]);
    expect(text(ev), 'ok');
    expect(s.calls, 1);
  });

  test('404 fails over without retry', () async {
    final b = await FakeServer.start();
    addTearDown(b.stop);
    s.script.add(FakeServer.status(404));
    b.script.add(FakeServer.sse([FakeServer.oaText('ok')]));
    await collect(client(), [cand(s.base, provider: 'A'), cand(b.base, provider: 'B')]);
    expect(s.calls, 1);
  });

  test('429 with Retry-After retries once then succeeds', () async {
    s.script.addAll([
      FakeServer.status(429, 'slow', {'retry-after': '1'}),
      FakeServer.sse([FakeServer.oaText('ok')]),
    ]);
    final ev = await collect(client(), [cand(s.base)]);
    expect(text(ev), 'ok');
    expect(s.calls, 2);
  });

  test('400 tools unsupported -> same model retried without tools', () async {
    s.script.addAll([
      FakeServer.status(400, 'No endpoints found that support tool use'),
      FakeServer.sse([FakeServer.oaText('plain')]),
    ]);
    final ev = await collect(client(), [cand(s.base)], tools: _tools);
    expect(text(ev), 'plain');
    expect(s.bodies[0].containsKey('tools'), isTrue);
    expect(s.bodies[1].containsKey('tools'), isFalse);
  });

  test('empty tools list is omitted from the payload', () async {
    s.script.add(FakeServer.sse([FakeServer.oaText('x')]));
    await collect(client(), [cand(s.base)], tools: const []);
    expect(s.bodies.first.containsKey('tools'), isFalse);
  });

  test('empty response retries once then fails over / errors', () async {
    s.script.add(FakeServer.sse([]));
    final e = await failure(client(), [cand(s.base)]);
    expect(e.kind, AiErrorKind.emptyResponse);
    expect(s.calls, 2);
  });

  test('hard cap: never more than 6 HTTP calls', () async {
    s.script.add(FakeServer.status(500));
    final cs = [for (var i = 0; i < 5; i++) cand(s.base, model: 'm$i')];
    final c = client();
    await failure(c, cs);
    expect(s.calls, lessThanOrEqualTo(6));
    expect(c.lastRunHttpCalls, lessThanOrEqualTo(6));
  });

  test('connection reset mid-stream: partial text is reset, retry succeeds', () async {
    s.script.addAll([
      FakeServer.reset([FakeServer.oaText('par')]),
      FakeServer.sse([FakeServer.oaText('full')]),
    ]);
    final ev = await collect(client(), [cand(s.base)]);
    expect(ev.any((e) => e.reset), isTrue);
    expect(ev.last.finalText, 'full');
  });

  test('never-ending stream hits idle timeout (no hang)', () async {
    s.script.add(FakeServer.hang([FakeServer.oaText('a')]));
    final e = await failure(client(), [cand(s.base)]);
    expect(e.kind, AiErrorKind.timeout);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('plain-http to a public host is refused before any request', () async {
    final e = await failure(client(), [cand('http://example.com/v1')]);
    expect(e.kind, AiErrorKind.badRequest);
  });

  test('Gemini: key only in header; path has no key', () async {
    s.script.add(FakeServer.sse([
      'data: {"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}',
    ], sendDone: false));
    final ev = await collect(client(), [cand('${s.base}/v1beta', provider: 'Gemini', model: 'gemini-2.5-flash')]);
    expect(ev.last.finalText, 'hi');
    expect(s.uris.first.toString().contains('KEY12345'), isFalse);
    expect(s.headers.first.value('x-goog-api-key'), 'KEY12345');
  });

  test('error text shown to users never contains the key', () async {
    s.script.add(FakeServer.status(401, '{"error":"invalid KEY12345"}'));
    final e = await failure(client(), [cand(s.base)]);
    expect(e.userMessage(isFa: false).contains('KEY12345'), isFalse);
    expect(e.toString().contains('KEY12345'), isFalse);
    expect((e.detail ?? '').contains('KEY12345'), isFalse);
  });
}
