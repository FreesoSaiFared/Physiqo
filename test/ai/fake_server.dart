import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local fake provider. Each request consumes the next behavior in [script];
/// the last behavior repeats. [requests] records every request body/headers.
typedef Behavior = Future<void> Function(HttpRequest req, Map<String, dynamic> body);

class FakeServer {
  late HttpServer _server;
  final List<Behavior> script = [];
  final List<Map<String, dynamic>> bodies = [];
  final List<HttpHeaders> headers = [];
  final List<Uri> uris = [];
  int _i = 0;

  int get calls => bodies.length;
  String get base => 'http://127.0.0.1:${_server.port}';

  static Future<FakeServer> start() async {
    final f = FakeServer();
    f._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    f._server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      Map<String, dynamic> body = {};
      try {
        final d = jsonDecode(text);
        if (d is Map) body = d.cast<String, dynamic>();
      } catch (_) {}
      f.bodies.add(body);
      f.headers.add(req.headers);
      f.uris.add(req.uri);
      final b = f.script[f._i < f.script.length ? f._i : f.script.length - 1];
      f._i++;
      try {
        await b(req, body);
      } catch (_) {}
    });
    return f;
  }

  Future<void> stop() => _server.close(force: true);

  // ---- behaviors -----------------------------------------------------------

  static Behavior status(int code, [String body = '{}', Map<String, String> h = const {}]) =>
      (req, _) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        h.forEach(req.response.headers.set);
        req.response.write(body);
        await req.response.close();
      };

  static Behavior sse(List<String> lines, {bool sendDone = true}) => (req, _) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final l in lines) {
          req.response.write('$l\n');
          await req.response.flush();
        }
        if (sendDone) req.response.write('data: [DONE]\n\n');
        await req.response.close();
      };

  static Behavior json(Map<String, dynamic> obj) => (req, _) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(obj));
        await req.response.close();
      };

  /// Sends [lines] then keeps the connection open without finishing.
  static Behavior hang(List<String> lines) => (req, _) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final l in lines) {
          req.response.write('$l\n');
        }
        await req.response.flush();
        await Future<void>.delayed(const Duration(seconds: 30));
        try {
          await req.response.close();
        } catch (_) {}
      };

  static Behavior reset(List<String> linesBefore) => (req, _) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final l in linesBefore) {
          req.response.write('$l\n');
        }
        await req.response.flush();
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
      };

  // ---- OpenAI-shaped payload helpers --------------------------------------

  static String oaText(String t) => 'data: ${jsonEncode({
        'choices': [
          {'delta': {'content': t}}
        ]
      })}';

  static String oaToolChunk({int? index, String? id, String? name, String? args}) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  if (index != null) 'index': index,
                  if (id != null) 'id': id,
                  'function': {
                    if (name != null) 'name': name,
                    if (args != null) 'arguments': args,
                  },
                }
              ]
            }
          }
        ]
      })}';
}
