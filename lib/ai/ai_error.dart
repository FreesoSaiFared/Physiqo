import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum AiErrorKind {
  auth,
  quota,
  rateLimited,
  modelNotFound,
  badRequest,
  toolsUnsupported,
  visionUnsupported,
  contextTooLong,
  payloadTooLarge,
  contentBlocked,
  network,
  timeout,
  server,
  emptyResponse,
  malformed,
  notConfigured,
}

/// A classified AI failure. [toString] never contains a response body, a URL
/// or a key, so it is safe to log and to show.
class AiError implements Exception {
  final AiErrorKind kind;
  final String provider;
  final String model;
  final int? statusCode;
  final Duration? retryAfter;

  /// Short, redacted, length-capped detail for developer logs only.
  final String? detail;

  const AiError(
    this.kind, {
    this.provider = '',
    this.model = '',
    this.statusCode,
    this.retryAfter,
    this.detail,
  });

  AiError withTarget(String provider, String model) => AiError(
        kind,
        provider: provider,
        model: model,
        statusCode: statusCode,
        retryAfter: retryAfter,
        detail: detail,
      );

  @override
  String toString() =>
      'AiError(${kind.name}${statusCode != null ? ' http=$statusCode' : ''}'
      '${provider.isNotEmpty ? ' provider=$provider' : ''}'
      '${model.isNotEmpty ? ' model=$model' : ''})';

  /// Text for the end user, built from [kind] only (never from raw bodies).
  /// Every message names exactly one thing to do.
  String userMessage({required bool isFa}) {
    final who = provider.isNotEmpty ? provider : (isFa ? 'سرویس' : 'the AI service');
    final m = model.isNotEmpty ? model : (isFa ? 'مدل' : 'the model');
    switch (kind) {
      case AiErrorKind.auth:
        return isFa
            ? 'کلید API برای $who پذیرفته نشد.\nکلید را در تنظیمات هوش مصنوعی بررسی و اصلاح کنید.'
            : 'The API key for $who was rejected.\nCheck or replace the key in AI settings.';
      case AiErrorKind.quota:
        return isFa
            ? 'سهمیه یا اعتبار $who تمام شده است.\nمدل یا ارائه‌دهنده دیگری انتخاب کنید یا بعداً تلاش کنید.'
            : 'The quota or credit for $who is used up.\nPick another model or provider, or try again later.';
      case AiErrorKind.rateLimited:
        return isFa
            ? 'محدودیت تعداد درخواست برای $m فعال شد.\nچند لحظه صبر کنید و دوباره تلاش کنید.'
            : 'Rate limit reached on $m.\nWait a moment and try again.';
      case AiErrorKind.modelNotFound:
        return isFa
            ? 'مدل $m دیگر وجود ندارد یا در دسترس نیست.\nدر تنظیمات مدل دیگری انتخاب کنید.'
            : '$m no longer exists or is not available.\nPick another model in settings.';
      case AiErrorKind.toolsUnsupported:
        return isFa
            ? 'مدل $m از ابزارها پشتیبانی نمی‌کند.\nمدل دیگری انتخاب کنید.'
            : '$m does not support tools.\nPick another model.';
      case AiErrorKind.visionUnsupported:
        return isFa
            ? 'مدل $m تصویر را پشتیبانی نمی‌کند.\nدر تنظیمات یک مدل بینایی انتخاب کنید.'
            : '$m cannot read images.\nChoose a vision model in settings.';
      case AiErrorKind.contextTooLong:
      case AiErrorKind.payloadTooLarge:
        return isFa
            ? 'درخواست برای $m بیش از حد بزرگ است.\nیک گفتگوی جدید شروع کنید یا تصویر کوچک‌تری بفرستید.'
            : 'The request is too large for $m.\nStart a new chat or send a smaller image.';
      case AiErrorKind.contentBlocked:
        return isFa
            ? 'مدل این درخواست را نپذیرفت.\nپیام را بازنویسی کنید و دوباره بفرستید.'
            : 'The model refused this request.\nRephrase your message and try again.';
      case AiErrorKind.network:
        return isFa
            ? 'ارتباط با $who برقرار نشد.\nاتصال اینترنت (و در صورت نیاز فیلترشکن) را بررسی کنید.'
            : 'Can\'t reach $who.\nCheck your internet connection and try again.';
      case AiErrorKind.timeout:
        return isFa
            ? '$who به‌موقع پاسخ نداد.\nدوباره تلاش کنید.'
            : '$who did not answer in time.\nTry again.';
      case AiErrorKind.server:
        return isFa
            ? 'سرور $who مشکل دارد.\nکمی بعد دوباره تلاش کنید.'
            : '$who is having problems.\nTry again in a little while.';
      case AiErrorKind.emptyResponse:
        return isFa
            ? '$m پاسخ خالی برگرداند.\nدوباره تلاش کنید یا مدل دیگری انتخاب کنید.'
            : '$m returned an empty answer.\nTry again or pick another model.';
      case AiErrorKind.malformed:
        return isFa
            ? 'پاسخ $m قابل‌فهم نبود.\nدوباره تلاش کنید یا مدل دیگری انتخاب کنید.'
            : 'The answer from $m was unreadable.\nTry again or pick another model.';
      case AiErrorKind.badRequest:
        return isFa
            ? '$who درخواست را نپذیرفت.\nمدل یا آدرس پایه را در تنظیمات بررسی کنید.'
            : '$who rejected the request.\nCheck the model and base URL in settings.';
      case AiErrorKind.notConfigured:
        return isFa
            ? 'هوش مصنوعی هنوز تنظیم نشده است.\nکلید API را در تنظیمات وارد کنید.'
            : 'The coach is not set up yet.\nAdd an API key in settings.';
    }
  }
}

class AiErrorMapper {
  /// Maps an HTTP failure to an [AiError]. [body] is only inspected, never
  /// stored beyond a short redacted [AiError.detail].
  static AiError fromHttp({
    required int status,
    required String body,
    String provider = '',
    String model = '',
    String? retryAfterHeader,
    String? apiKey,
  }) {
    final b = body.toLowerCase();
    final retryAfter = parseRetryAfter(retryAfterHeader);
    AiErrorKind kind;

    bool has(String s) => b.contains(s);

    if (status == 401) {
      kind = AiErrorKind.auth;
    } else if (status == 403) {
      kind = (has('quota') || has('billing') || has('credit'))
          ? AiErrorKind.quota
          : AiErrorKind.auth;
    } else if (status == 402) {
      kind = AiErrorKind.quota;
    } else if (status == 404) {
      kind = AiErrorKind.modelNotFound;
    } else if (status == 408) {
      kind = AiErrorKind.timeout;
    } else if (status == 413) {
      kind = AiErrorKind.payloadTooLarge;
    } else if (status == 429) {
      kind = (has('insufficient_quota') ||
              has('billing') ||
              has('exceeded your current quota') ||
              has('credit balance'))
          ? AiErrorKind.quota
          : AiErrorKind.rateLimited;
    } else if (status >= 500) {
      kind = AiErrorKind.server;
    } else if (status == 400 || status == 422) {
      kind = _classify400(b);
    } else {
      kind = AiErrorKind.badRequest;
    }

    return AiError(
      kind,
      provider: provider,
      model: model,
      statusCode: status,
      retryAfter: retryAfter,
      detail: redact(body, apiKey: apiKey, maxLen: 300),
    );
  }

  static AiErrorKind _classify400(String b) {
    bool has(String s) => b.contains(s);
    if (has('api key not valid') ||
        has('api_key_invalid') ||
        has('invalid api key') ||
        has('invalid x-api-key')) {
      return AiErrorKind.auth;
    }
    final mentionsTools = has('tool') || has('function');
    if (mentionsTools &&
        (has('not support') ||
            has('unsupported') ||
            has('does not support') ||
            has('no endpoints found that support tool') ||
            has('minitems') ||
            has('too short') ||
            has('empty array') ||
            has('must not be empty') ||
            has('should be non-empty'))) {
      return AiErrorKind.toolsUnsupported;
    }
    if ((has('image') || has('vision') || has('multimodal') || has('modalit')) &&
        (has('not support') || has('unsupported') || has('does not support'))) {
      return AiErrorKind.visionUnsupported;
    }
    if (has('context length') ||
        has('context_length') ||
        has('maximum context') ||
        has('too long') ||
        has('token limit') ||
        has('exceeds the maximum') ||
        has('input token count') ||
        has('prompt is too long')) {
      return AiErrorKind.contextTooLong;
    }
    if (has('content_filter') ||
        has('content filter') ||
        has('safety') ||
        has('blocked')) {
      return AiErrorKind.contentBlocked;
    }
    if (has('model') &&
        (has('not found') || has('does not exist') || has('is not supported'))) {
      return AiErrorKind.modelNotFound;
    }
    return AiErrorKind.badRequest;
  }

  /// Maps a thrown transport-level exception (never an [AiError]).
  static AiError fromException(Object e, {String provider = '', String model = ''}) {
    if (e is AiError) return e.withTarget(
        e.provider.isEmpty ? provider : e.provider,
        e.model.isEmpty ? model : e.model);
    if (e is TimeoutException) {
      return AiError(AiErrorKind.timeout, provider: provider, model: model);
    }
    if (e is SocketException ||
        e is HandshakeException ||
        e is http.ClientException ||
        e is TlsException) {
      return AiError(AiErrorKind.network, provider: provider, model: model);
    }
    if (e is FormatException) {
      return AiError(AiErrorKind.malformed, provider: provider, model: model);
    }
    return AiError(AiErrorKind.network,
        provider: provider,
        model: model,
        detail: redact(e.runtimeType.toString(), maxLen: 80));
  }

  static Duration? parseRetryAfter(String? header) {
    if (header == null) return null;
    final secs = int.tryParse(header.trim());
    if (secs == null || secs < 0) return null;
    return Duration(seconds: secs);
  }

  /// Removes secrets and bulky data from text before it is kept anywhere.
  static String redact(String s, {String? apiKey, int maxLen = 500}) {
    var out = s;
    if (apiKey != null && apiKey.length >= 8) {
      out = out.replaceAll(apiKey, '[redacted-key]');
    }
    out = out.replaceAll(RegExp(r'AIza[0-9A-Za-z_\-]{20,}'), '[redacted-key]');
    out = out.replaceAll(RegExp(r'sk-[0-9A-Za-z_\-]{16,}'), '[redacted-key]');
    out = out.replaceAll(RegExp(r'[A-Za-z0-9+/=]{200,}'), '[base64 omitted]');
    if (out.length > maxLen) out = '${out.substring(0, maxLen)}…';
    return out;
  }

  /// Convenience for building an error from a JSON `error` object that arrived
  /// inside a 200-OK stream.
  static AiError fromStreamErrorObject(
    dynamic errorObj, {
    String provider = '',
    String model = '',
    String? apiKey,
  }) {
    var status = 500;
    if (errorObj is Map) {
      final code = errorObj['code'];
      if (code is int) status = code;
      if (code is String) status = int.tryParse(code) ?? status;
      if (errorObj['status'] is int) status = errorObj['status'] as int;
    }
    String body;
    try {
      body = jsonEncode(errorObj);
    } catch (_) {
      body = errorObj.toString();
    }
    return fromHttp(
        status: status, body: body, provider: provider, model: model, apiKey: apiKey);
  }
}
