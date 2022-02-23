// Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
// This product includes software developed at Datadog (https://www.datadoghq.com/).
// Copyright 2019-2021 Datadog, Inc.

import '../helpers.dart';
import '../internal_logger.dart';
import 'ddtraces_platform_interface.dart';


/// A collection of standard `Span` tag keys defined by Open Tracing.
/// Use them as the `key` in [DdSpan.setTag]. Use the expected type for the `value`.
///
/// See more: [Span tags table](https://github.com/opentracing/specification/blob/master/semantic_conventions.md#span-tags-table)
class OTTags {
  /// Expected value: `String`.
  static const component = 'component';

  /// Expected value: `String`
  static const dbInstance = 'db.instance';

  /// Expected value: `String`
  static const dbStatement = 'db.statement';

  /// Expected value: `String`
  static const dbType = 'db.type';

  /// Expected value: `String`
  static const dbUser = 'db.user';

  /// Expected value: `Bool`
  static const error = 'error';

  /// Expected value: `String`
  static const httpMethod = 'http.method';

  /// Expected value: `Int`
  static const httpStatusCode = 'http.status_code';

  /// Expected value: `String`
  static const httpUrl = 'http.url';

  /// Expected value: `String`
  static const messageBusDestination = 'message_bus.destination';

  /// Expected value: `String`
  static const peerAddress = 'peer.address';

  /// Expected value: `String`
  static const peerHostname = 'peer.hostname';

  /// Expected value: `String`
  static const peerIPv4 = 'peer.ipv4';

  /// Expected value: `String`
  static const peerIPv6 = 'peer.ipv6';

  /// Expected value: `Int`
  static const peerPort = 'peer.port';

  /// Expected value: `String`
  static const peerService = 'peer.service';

  /// Expected value: `Int`
  static const samplingPriority = 'sampling.priority';

  /// Expected value: `String`
  static const spanKind = 'span.kind';
}

/// A collection of standard `Span` log fields defined by Open Tracing.
/// Use them as the `key` for `fields` dictionary in [DdSpan.log]. Use the expected type for the value.
///
/// See more: [Log fields table](https://github.com/opentracing/specification/blob/master/semantic_conventions.md#log-fields-table)
///
class OTLogFields {
  /// Expected value: `String`
  static const errorKind = 'error.kind';

  /// Expected value: `String`
  static const event = 'event';

  /// Expected value: `String`
  static const message = 'message';

  /// Expected value: `String`
  static const stack = 'stack';
}

class DdSpan {
  static String closedSpanWarning(String method) =>
      'Attempting to call $method on a closed span.';

  final DdTracesPlatform _platform;
  InternalLogger? _logger;

  int _handle;
  int get handle => _handle;

  DdSpan(this._platform, this._handle);

  Future<void> setActive() {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('setActivate'));
      return Future.value();
    }

    return _platform.spanSetActive(this);
  }

  Future<void> setBaggageItem(String key, String value) {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('setBaggageItem'));
      return Future.value();
    }

    return _platform.spanSetBaggageItem(this, key, value);
  }

  /// Set a tag with the given [key] to the given [value]. Although the type for
  /// [value] is dynamic, the object passed in must be one of the types
  /// supported by the [StandardMessageCodec]
  Future<void> setTag(String key, dynamic value) {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('setTag'));
      return Future.value();
    }

    return _platform.spanSetTag(this, key, value);
  }

  Future<void> setError(Exception error, [StackTrace? stackTrace]) {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('setError'));
      return Future.value();
    }

    return setErrorInfo(
        error.runtimeType.toString(), error.toString(), stackTrace);
  }

  Future<void> setErrorInfo(
      String kind, String message, StackTrace? stackTrace) {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('setErrorInfo'));
      return Future.value();
    }
    stackTrace ??= StackTrace.current;

    return _platform.spanSetError(this, kind, message, stackTrace.toString());
  }

  Future<void> log(Map<String, Object?> fields) {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('log'));
      return Future.value();
    }

    return _platform.spanLog(this, fields);
  }

  Future<void> finish() async {
    if (_handle <= 0) {
      _logger?.warn(closedSpanWarning('finish'));
      return Future.value();
    }

    await _platform.spanFinish(this);
    _handle = -1;
  }
}

class DdTraces {
  static DdTracesPlatform get _platform {
    return DdTracesPlatform.instance;
  }

  final InternalLogger _logger;

  DdTraces(this._logger);

  Future<DdSpan> startSpan(
    String operationName, {
    DdSpan? parentSpan,
    String? resourceName,
    Map<String, dynamic>? tags,
    DateTime? startTime,
  }) async {
    final span = await wrap('traces.startSpan', _logger, () async {
      var span = await _platform.startSpan(
          operationName, parentSpan, resourceName, tags, startTime);
      if (span != null) {
        span._logger = _logger;
      } else {
        _logger.error('Error creating span named $operationName');
        // Don't set the logger on this span or it will spam being closed
        span = DdSpan(_platform, 0);
      }
      return span;
    });

    return span ?? DdSpan(_platform, 0);
  }

  Future<DdSpan> startRootSpan(
    String operationName, {
    String? resourceName,
    Map<String, dynamic>? tags,
    DateTime? startTime,
  }) async {
    final span = await wrap('traces.startRootSpan', _logger, () async {
      var span = await _platform.startRootSpan(
          operationName, resourceName, tags, startTime);
      if (span != null) {
        span._logger = _logger;
      } else {
        _logger.error('Error creating span named $operationName');
        // Don't set the logger on this span or it will spam being closed
        span = DdSpan(_platform, 0);
      }
      return span;
    });

    return span ?? DdSpan(_platform, 0);
  }

  Future<Map<String, String>> getTracePropagationHeaders(DdSpan span) async {
    final headers =
        await wrap('traces.getTracePropagationHeaders', _logger, () async {
      return _platform.getTracePropagationHeaders(span);
    });

    return headers ?? {};
  }
}
