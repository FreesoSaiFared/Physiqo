/// Server-Sent-Events line helpers.
class SseLine {
  /// Payload of a `data:` line (without the field name), or null when the
  /// line carries no data (comment, `event:`, `id:`, `retry:`, blank).
  final String? data;

  /// True when the payload is the `[DONE]` sentinel.
  final bool isDone;

  const SseLine(this.data, {this.isDone = false});

  static const SseLine none = SseLine(null);

  /// Accepts `data: {...}` and `data:{...}`; ignores everything else.
  static SseLine parse(String line) {
    if (line.isEmpty || line.startsWith(':')) return none;
    if (!line.startsWith('data:')) return none;
    var payload = line.substring(5);
    if (payload.startsWith(' ')) payload = payload.substring(1);
    payload = payload.trim();
    if (payload.isEmpty) return none;
    if (payload == '[DONE]') return const SseLine(null, isDone: true);
    return SseLine(payload);
  }
}
