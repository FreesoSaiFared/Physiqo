import 'ai_error.dart';

/// What the client should do after an attempt failed.
enum AiAction {
  /// Same model again, after [AiPolicyDecision.delay].
  retrySame,

  /// Same model again, but without tools (model/endpoint rejects them).
  retryWithoutTools,

  /// Same model again with a smaller request (less history, smaller images).
  retryReduced,

  /// Give up on this model, try the next candidate.
  failover,

  /// Give up on this model AND every other model of the same provider
  /// (the key is bad), try candidates of other providers only.
  failoverSkipProvider,

  /// Stop completely and report the error.
  abort,
}

class AiPolicyDecision {
  final AiAction action;
  final Duration delay;
  const AiPolicyDecision(this.action, [this.delay = Duration.zero]);

  @override
  String toString() => 'AiPolicyDecision(${action.name}, ${delay.inMilliseconds}ms)';
}

/// Hard limits for one user message.
class AiLimits {
  /// Max HTTP calls for one user message, retries and failovers included.
  static const int maxHttpCalls = 6;

  /// Max tool-loop iterations the chat screen may run for one user message.
  static const int maxToolLoops = 5;

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration firstByteTimeout = Duration(seconds: 30);
  static const Duration firstByteTimeoutThinking = Duration(seconds: 60);
  static const Duration idleTimeout = Duration(seconds: 30);
  static const Duration maxRetryAfter = Duration(seconds: 20);
}

/// Counts HTTP calls against [AiLimits.maxHttpCalls].
class AiCallBudget {
  final int max;
  int _used = 0;
  AiCallBudget({this.max = AiLimits.maxHttpCalls});

  int get used => _used;
  bool get exhausted => _used >= max;

  /// Returns false (and consumes nothing) when the budget is spent.
  bool tryConsume() {
    if (_used >= max) return false;
    _used++;
    return true;
  }
}

class AiRetryPolicy {
  static const List<Duration> _networkBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// [attempt] is 1 for the first try on this model.
  /// [jitterMs] is added to backoff delays (injectable for tests; pass 0).
  static AiPolicyDecision decide(
    AiError e, {
    required int attempt,
    required bool toolsEnabled,
    required bool reducedAlready,
    int jitterMs = 0,
  }) {
    switch (e.kind) {
      case AiErrorKind.network:
      case AiErrorKind.timeout:
        // Up to 2 retries (3 tries) with 1s / 3s backoff.
        if (attempt <= _networkBackoff.length) {
          return AiPolicyDecision(
            AiAction.retrySame,
            _networkBackoff[attempt - 1] + Duration(milliseconds: jitterMs),
          );
        }
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.rateLimited:
        // One retry, honouring Retry-After, but never wait longer than the cap.
        final wait = e.retryAfter ?? const Duration(seconds: 2);
        if (attempt < 2 && wait <= AiLimits.maxRetryAfter) {
          return AiPolicyDecision(AiAction.retrySame, wait);
        }
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.server:
        if (attempt < 2) {
          return AiPolicyDecision(
              AiAction.retrySame, const Duration(seconds: 1) + Duration(milliseconds: jitterMs));
        }
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.emptyResponse:
      case AiErrorKind.malformed:
        if (attempt < 2) return const AiPolicyDecision(AiAction.retrySame);
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.auth:
        return const AiPolicyDecision(AiAction.failoverSkipProvider);

      case AiErrorKind.quota:
      case AiErrorKind.modelNotFound:
      case AiErrorKind.visionUnsupported:
      case AiErrorKind.badRequest:
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.toolsUnsupported:
        if (toolsEnabled) return const AiPolicyDecision(AiAction.retryWithoutTools);
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.contextTooLong:
      case AiErrorKind.payloadTooLarge:
        if (!reducedAlready) return const AiPolicyDecision(AiAction.retryReduced);
        return const AiPolicyDecision(AiAction.failover);

      case AiErrorKind.contentBlocked:
        return const AiPolicyDecision(AiAction.abort);

      case AiErrorKind.notConfigured:
        return const AiPolicyDecision(AiAction.abort);
    }
  }
}
