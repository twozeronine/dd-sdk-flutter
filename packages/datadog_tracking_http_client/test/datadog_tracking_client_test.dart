// Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
// This product includes software developed at Datadog (https://www.datadoghq.com/).
// Copyright 2019-2022 Datadog, Inc.

import 'dart:async';
import 'dart:io';

import 'package:datadog_flutter_plugin/datadog_flutter_plugin.dart';
import 'package:datadog_flutter_plugin/datadog_internal.dart';
import 'package:datadog_tracking_http_client/src/tracking_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'test_utils.dart';

class MockDatadogSdk extends Mock implements DatadogSdk {}

class MockDatadogSdkPlatform extends Mock implements DatadogSdkPlatform {}

class MockDdRum extends Mock implements DdRum {}

class MockClient extends Mock implements http.Client {}

class MockStreamedResponse extends Mock implements http.StreamedResponse {}

class FakeBaseRequest extends Fake implements http.BaseRequest {}

void main() {
  late MockDatadogSdk mockDatadog;
  late MockDatadogSdkPlatform mockPlatform;
  late MockClient mockClient;
  late MockStreamedResponse mockResponse;

  setUpAll(() {
    registerFallbackValue(Uri());
    registerFallbackValue(FakeBaseRequest());
  });

  setUp(() {
    mockPlatform = MockDatadogSdkPlatform();
    when(() => mockPlatform.updateTelemetryConfiguration(any(), any()))
        .thenAnswer((_) => Future<void>.value());

    mockDatadog = MockDatadogSdk();
    when(() => mockDatadog.isFirstPartyHost(
        any(that: HasHost(equals('test_url'))))).thenReturn(true);
    when(() => mockDatadog.isFirstPartyHost(
        any(that: HasHost(equals('non_first_party'))))).thenReturn(false);
    when(() => mockDatadog.platform).thenReturn(mockPlatform);

    mockResponse = MockStreamedResponse();
    when(() => mockResponse.stream)
        .thenAnswer((_) => http.ByteStream.fromBytes([]));
    when(() => mockResponse.statusCode).thenReturn(200);
    when(() => mockResponse.persistentConnection).thenReturn(false);
    when(() => mockResponse.request).thenReturn(FakeBaseRequest());
    when(() => mockResponse.headers).thenReturn({});
    when(() => mockResponse.isRedirect).thenReturn(false);

    mockClient = MockClient();
    when(() => mockClient.send(any()))
        .thenAnswer((_) => Future.value(mockResponse));
  });

  void verifyHeaders(Map<String, String> headers, TracingHeaderType type) {
    BigInt? traceInt;
    BigInt? spanInt;

    switch (type) {
      case TracingHeaderType.dd:
        expect(headers['x-datadog-sampling-priority'], '1');
        traceInt = BigInt.tryParse(headers['x-datadog-trace-id']!);
        spanInt = BigInt.tryParse(headers['x-datadog-parent-id']!);
        break;
      case TracingHeaderType.b3s:
        var singleHeader = headers['b3']!;
        var headerParts = singleHeader.split('-');
        traceInt = BigInt.tryParse(headerParts[0], radix: 16);
        spanInt = BigInt.tryParse(headerParts[1], radix: 16);
        expect(headerParts[2], '1');
        break;
      case TracingHeaderType.b3m:
        expect(headers['X-B3-Sampled'], '1');
        traceInt = BigInt.tryParse(headers['X-B3-TraceId']!, radix: 16);
        spanInt = BigInt.tryParse(headers['X-B3-SpanId']!, radix: 16);
        break;
    }

    expect(traceInt, isNotNull);
    expect(traceInt?.bitLength, lessThanOrEqualTo(63));

    expect(spanInt, isNotNull);
    expect(spanInt?.bitLength, lessThanOrEqualTo(63));
  }

  group('when rum is disabled', () {
    setUp(() {
      when(() => mockDatadog.rum).thenReturn(null);
    });

    test('tracking client passes through send calls', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');
      await client.get(testUri, headers: {'x-datadog-header': 'header'});

      final captured = verify(() => mockClient.send(captureAny())).captured[0]
          as http.BaseRequest;
      expect(captured.url, testUri);
      expect(captured.headers, {'x-datadog-header': 'header'});
    });
  });

  group('when rum is enabled', () {
    late MockDdRum mockRum;

    setUp(() {
      mockRum = MockDdRum();
      when(() => mockRum.shouldSampleTrace()).thenReturn(true);
      when(() => mockRum.tracingSamplingRate).thenReturn(50.0);

      when(() => mockDatadog.rum).thenReturn(mockRum);
    });

    test('calls startResourceLoading on initial request', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');
      final _ = client.get(testUri, headers: {'x-datadog-header': 'header'});

      verify(() => mockRum.startResourceLoading(
          any(), RumHttpMethod.get, testUri.toString(), any()));
    });

    test('calls stopResourceLoading on completion', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');
      final future =
          client.get(testUri, headers: {'x-datadog-header': 'header'});

      await future;

      final key = verify(() => mockRum.startResourceLoading(
              captureAny(), RumHttpMethod.get, testUri.toString(), any()))
          .captured[0] as String;

      verify(() => mockRum.stopResourceLoading(
          key, 200, RumResourceType.native, any(), any()));
    });

    test('calls stopResourceLoading with size and deduced content type',
        () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      when(() => mockResponse.contentLength).thenReturn(88888);
      when(() => mockResponse.headers).thenReturn({
        HttpHeaders.contentTypeHeader: ContentType('image', 'png').toString()
      });
      final future =
          client.get(testUri, headers: {'x-datadog-header': 'header'});

      await future;

      final key = verify(() => mockRum.startResourceLoading(
              captureAny(), RumHttpMethod.get, testUri.toString(), any()))
          .captured[0] as String;

      verify(() => mockRum.stopResourceLoading(
          key, 200, RumResourceType.image, 88888, any()));
    });

    test(
        'send throwingError rethrows and calls stopResourceLoadingWithErrorInfo',
        () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      final errorToThrow = Error();
      Object? thrownError;
      when(() => mockClient.send(any())).thenThrow(errorToThrow);
      try {
        final _ =
            await client.get(testUri, headers: {'x-datadog-header': 'header'});
      } catch (e) {
        thrownError = e;
      }

      final key = verify(() => mockRum.startResourceLoading(
              captureAny(), RumHttpMethod.get, testUri.toString(), any()))
          .captured[0] as String;

      expect(thrownError, thrownError);
      verify(() => mockRum.stopResourceLoadingWithErrorInfo(
          key, thrownError.toString(), thrownError.runtimeType.toString()));
    });

    test('passes through stream data', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      when(() => mockResponse.stream).thenAnswer(
          (_) => http.ByteStream.fromBytes([1, 2, 3, 4, 5, 122, 121, 120]));

      final response =
          await client.get(testUri, headers: {'x-datadog-header': 'header'});

      expect(response.bodyBytes.toList(), [1, 2, 3, 4, 5, 122, 121, 120]);
    });

    test('error in stream and calls stopResourceLoadingWithErrorInfo',
        () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      final errorToThrow = Error();
      final streamController = StreamController<List<int>>();
      Object? thrownError;
      when(() => mockResponse.stream)
          .thenAnswer((_) => http.ByteStream(streamController.stream));

      final future =
          client.get(testUri, headers: {'x-datadog-header': 'header'});

      try {
        streamController.sink.addError(errorToThrow);

        await future;
      } catch (e) {
        thrownError = e;
      }

      expect(errorToThrow, thrownError);
      final key = verify(() => mockRum.startResourceLoading(
              captureAny(), RumHttpMethod.get, testUri.toString(), any()))
          .captured[0] as String;

      verify(() => mockRum.stopResourceLoadingWithErrorInfo(
          key, errorToThrow.toString(), errorToThrow.runtimeType.toString()));
    });

    test('extracts b3s headers and sets attributes', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      // Randomly generated
      //  - 714e65427868bdc8 == 8164574510631665096
      //  - 7386a57f63c48531 == 8324522927794193713
      final _ = client.get(testUri, headers: {
        'b3': '0000000000000000714E65427868BDC8-7386A57F63C48531-1'
      });

      final capturedRequest = verify(() => mockClient.send(captureAny()))
          .captured[0] as http.BaseRequest;
      expect(capturedRequest.url, testUri);
      final capturedAttributes = verify(() => mockRum.startResourceLoading(
              any(), RumHttpMethod.get, testUri.toString(), captureAny()))
          .captured[0] as Map<String, Object?>;

      final headers = capturedRequest.headers;

      var traceInt = BigInt.parse(
          capturedAttributes[DatadogRumPlatformAttributeKey.traceID] as String);
      expect(traceInt, BigInt.from(0x714e65427868bdc8));
      var spanInt = BigInt.parse(
          capturedAttributes[DatadogRumPlatformAttributeKey.spanID] as String);
      expect(spanInt, BigInt.from(0x7386a57f63c48531));
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.rulePsr], 0.5);

      expect(headers['x-datadog-trace-id'], '8164574510631665096');
      expect(headers['x-datadog-parent-id'], '8324522927794193713');
    });

    test('extracts b3m headers and sets attributes', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      // Randomly generated
      //  - 714e65427868bdc8 == 8164574510631665096
      //  - 7386a57f63c48531 == 8324522927794193713
      final _ = client.get(testUri, headers: {
        'X-B3-TraceId': '0000000000000000714E65427868BDC8',
        'X-B3-SpanId': '7386A57F63C48531',
        'X-B3-Sampled': '1',
      });

      final capturedRequest = verify(() => mockClient.send(captureAny()))
          .captured[0] as http.BaseRequest;
      expect(capturedRequest.url, testUri);
      final capturedAttributes = verify(() => mockRum.startResourceLoading(
              any(), RumHttpMethod.get, testUri.toString(), captureAny()))
          .captured[0] as Map<String, Object?>;

      final headers = capturedRequest.headers;

      var traceInt = BigInt.parse(
          capturedAttributes[DatadogRumPlatformAttributeKey.traceID] as String);
      expect(traceInt, BigInt.from(0x714e65427868bdc8));
      var spanInt = BigInt.parse(
          capturedAttributes[DatadogRumPlatformAttributeKey.spanID] as String);
      expect(spanInt, BigInt.from(0x7386a57f63c48531));
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.rulePsr], 0.5);

      expect(headers['x-datadog-trace-id'], '8164574510631665096');
      expect(headers['x-datadog-parent-id'], '8324522927794193713');
    });

    test('extracts b3m headers and sets attributes case insensitive', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      // Randomly generated
      //  - 714e65427868bdc8 == 8164574510631665096
      //  - 7386a57f63c48531 == 8324522927794193713
      final _ = client.get(testUri, headers: {
        'x-b3-traceid': '0000000000000000714E65427868BDC8',
        'x-b3-spanid': '7386A57F63C48531',
        'x-b3-sampled': '1',
      });

      final capturedRequest = verify(() => mockClient.send(captureAny()))
          .captured[0] as http.BaseRequest;
      expect(capturedRequest.url, testUri);
      final capturedAttributes = verify(() => mockRum.startResourceLoading(
              any(), RumHttpMethod.get, testUri.toString(), captureAny()))
          .captured[0] as Map<String, Object?>;

      final headers = capturedRequest.headers;

      var traceInt = BigInt.parse(
          capturedAttributes[DatadogRumPlatformAttributeKey.traceID] as String);
      expect(traceInt, BigInt.from(0x714e65427868bdc8));
      var spanInt = BigInt.parse(
          capturedAttributes[DatadogRumPlatformAttributeKey.spanID] as String);
      expect(spanInt, BigInt.from(0x7386a57f63c48531));
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.rulePsr], 0.5);

      expect(headers['x-datadog-trace-id'], '8164574510631665096');
      expect(headers['x-datadog-parent-id'], '8324522927794193713');
    });

    test('extracts b3s unsampled to datadog unsampled', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      final _ = client.get(testUri, headers: {
        'b3': '0',
      });

      final capturedRequest = verify(() => mockClient.send(captureAny()))
          .captured[0] as http.BaseRequest;
      expect(capturedRequest.url, testUri);
      final capturedAttributes = verify(() => mockRum.startResourceLoading(
              any(), RumHttpMethod.get, testUri.toString(), captureAny()))
          .captured[0] as Map<String, Object?>;

      final headers = capturedRequest.headers;

      expect(
          capturedAttributes[DatadogRumPlatformAttributeKey.traceID], isNull);
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.spanID], isNull);
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.rulePsr], 0.5);

      expect(headers['x-datadog-sampling-priority'], '0');
    });

    test('extracts b3m unsampled to datadog unsampled', () async {
      final client =
          DatadogClient(datadogSdk: mockDatadog, innerClient: mockClient);
      final testUri = Uri.parse('https://test_url/test');

      final _ = client.get(testUri, headers: {
        'X-B3-Sampled': '0',
      });

      final capturedRequest = verify(() => mockClient.send(captureAny()))
          .captured[0] as http.BaseRequest;
      expect(capturedRequest.url, testUri);
      final capturedAttributes = verify(() => mockRum.startResourceLoading(
              any(), RumHttpMethod.get, testUri.toString(), captureAny()))
          .captured[0] as Map<String, Object?>;

      final headers = capturedRequest.headers;

      expect(
          capturedAttributes[DatadogRumPlatformAttributeKey.traceID], isNull);
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.spanID], isNull);
      expect(capturedAttributes[DatadogRumPlatformAttributeKey.rulePsr], 0.5);

      expect(headers['x-datadog-sampling-priority'], '0');
    });

    for (final headerType in TracingHeaderType.values) {
      group('when rum is enabled with $headerType tracing headers', () {
        test('adds tracing headers to request', () async {
          final client = DatadogClient(
            datadogSdk: mockDatadog,
            tracingHeaderTypes: {headerType},
            innerClient: mockClient,
          );
          final testUri = Uri.parse('https://test_url/test');
          final _ =
              client.get(testUri, headers: {'x-datadog-header': 'header'});

          final captured = verify(() => mockClient.send(captureAny()))
              .captured[0] as http.BaseRequest;
          expect(captured.url, testUri);

          final headers = captured.headers;

          verifyHeaders(headers, headerType);
        });

        test('adds tracing attributes to startResourceLoading', () async {
          final client = DatadogClient(
            datadogSdk: mockDatadog,
            tracingHeaderTypes: {headerType},
            innerClient: mockClient,
          );
          final testUri = Uri.parse('https://test_url/test');
          final _ =
              client.get(testUri, headers: {'x-datadog-header': 'header'});

          final callAttributes = verify(() => mockRum.startResourceLoading(
                  any(), RumHttpMethod.get, testUri.toString(), captureAny()))
              .captured[0] as Map<String, Object?>;

          final traceValue = callAttributes['_dd.trace_id'] as String?;
          final traceInt =
              traceValue != null ? BigInt.tryParse(traceValue) : null;
          expect(traceInt, isNotNull);
          expect(traceInt?.bitLength, lessThanOrEqualTo(63));

          final spanValue = callAttributes['_dd.span_id'] as String?;
          final spanInt = spanValue != null ? BigInt.tryParse(spanValue) : null;
          expect(spanInt, isNotNull);
          expect(spanInt?.bitLength, lessThanOrEqualTo(63));
        });

        test('does not trace 3rd party requests', () async {
          final client = DatadogClient(
            datadogSdk: mockDatadog,
            tracingHeaderTypes: {headerType},
            innerClient: mockClient,
          );
          final testUri = Uri.parse('https://non_first_party/test');
          final _ =
              client.get(testUri, headers: {'x-datadog-header': 'header'});

          final captured = verify(() => mockClient.send(captureAny()))
              .captured[0] as http.BaseRequest;
          expect(captured.url, testUri);

          final headers = captured.headers;
          expect(headers['x-datadog-header'], 'header');

          expect(headers['x-datadog-sampling-priority'], isNull);
          expect(headers['x-datadog-trace-id'], isNull);
          expect(headers['x-datadog-parent-id'], isNull);
          expect(headers['b3'], isNull);
          expect(headers['X-B3-TraceId'], isNull);
          expect(headers['X-B3-SpanId'], isNull);
          expect(headers['X-B3-ParentSpanId'], isNull);
          expect(headers['X-B3-Sampled'], isNull);

          final callAttributes = verify(() => mockRum.startResourceLoading(
                  any(), RumHttpMethod.get, testUri.toString(), captureAny()))
              .captured[0] as Map<String, Object?>;
          expect(callAttributes['_dd.trace_id'], isNull);
          expect(callAttributes['_dd.parent_id'], isNull);
        });
      });
    }
  });
}