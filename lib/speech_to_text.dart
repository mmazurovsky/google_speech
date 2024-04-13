library flutter_google_speech;

import 'dart:async';

import 'package:google_speech/auth/third_party_authenticator.dart';
import 'package:google_speech/config/longrunning_result.dart';
import 'package:google_speech/generated/google/cloud/speech/v1/cloud_speech.pbgrpc.dart' hide RecognitionConfig, StreamingRecognitionConfig;
import 'package:google_speech/generated/google/longrunning/operations.pbgrpc.dart';
import 'package:google_speech/speech_client_authenticator.dart';
import 'package:grpc/grpc.dart';

import 'config/recognition_config_v1.dart';
import 'config/streaming_recognition_config.dart';

/// An interface to Google's Speech-to-Text Api via grpc.
///
/// Important! You need an own Google project to use this class.
class SpeechToText {
  /// [CallOptions] that are transferred when creating a [SpeechClient].
  final CallOptions _options;

  /// [ClientChannel] which is used for the Google Speech-to-Text Api.
  final ClientChannel _channel;

  // Private constructor to prevent direct initialization of the class.
  SpeechToText._(
    this._options, {
    String? cloudSpeechEndpoint,
  }) : _channel = ClientChannel(cloudSpeechEndpoint ?? 'speech.googleapis.com');

  /// Creates a SpeechToText interface using a service account.
  factory SpeechToText.viaServiceAccount(ServiceAccount account, {String? cloudSpeechEndpoint}) =>
      SpeechToText._(account.callOptions, cloudSpeechEndpoint: cloudSpeechEndpoint);

  /// Creates a SpeechToText interface using a API keys.
  factory SpeechToText.viaApiKey(String apiKey, {String? cloudSpeechEndpoint}) =>
      SpeechToText._(CallOptions(metadata: {'X-goog-api-key': '$apiKey'}), cloudSpeechEndpoint: cloudSpeechEndpoint);

  /// Creates a SpeechToText interface using a third party authenticator.
  /// Don't worry about updating the access token, the package does it automatically.
  /// Example:
  ///       final speechToText = SpeechToText.viaThirdPartyAuthenticator(
  ///         ThirdPartyAuthenticator(
  ///           obtainCredentialsFromThirdParty: () async {
  ///             // request api to get token
  ///             final json = await requestCredentialFromMyApi();
  ///             return AccessCredentials.fromJson(json);
  ///           },
  ///         ),
  ///       );
  factory SpeechToText.viaThirdPartyAuthenticator(ThirdPartyAuthenticator thirdPartyAuthenticator, {String? cloudSpeechEndpoint}) =>
      SpeechToText._(thirdPartyAuthenticator.toCallOptions, cloudSpeechEndpoint: cloudSpeechEndpoint);

  /// Creates a SpeechToText interface using a token.
  /// You are responsible for updating the token when it expires.
  factory SpeechToText.viaToken(String typeToken, String token, {String? cloudSpeechEndpoint}) =>
      SpeechToText._(CallOptions(metadata: {'authorization': '$typeToken $token'}), cloudSpeechEndpoint: cloudSpeechEndpoint);

  /// Listen to audio stream.
  /// Cancelled as soon as dispose is called.
  StreamSubscription<List<int>>? _audioStreamSubscription;

  /// Sends a [RecognizeRequest] request to the Google Speech Api.
  /// Requires a [RecognitionConfig] and an [RecognitionAudio].
  ///
  /// Audio files transcribed with recognize must not be longer than 60 seconds.
  /// For longer audio files [longRunningRecognize] must be used.
  Future<RecognizeResponse> recognize(RecognitionConfig config, List<int> audio) {
    final client = SpeechClient(_channel, options: _options);

    // transform audio to RecognitionAudio
    final recognitionAudio = RecognitionAudio()..content = audio;

    // Create the request, which transmits the necessary
    // data to the Google Api.
    final request = (RecognizeRequest()
      ..config = config.toConfig()
      ..audio = recognitionAudio);
    return client.recognize(request);
  }

  /// Sends a [StreamingRecognizeRequest] to the Google Speech Api.
  /// Requires a [StreamingRecognitionConfig] and an audioStream.
  Stream<StreamingRecognizeResponse> streamingRecognize(StreamingRecognitionConfig config, Stream<List<int>> audioStream) {
    final client = SpeechClient(_channel, options: _options);

    // Create the stream, which later transmits the necessary
    // data to the Google Api.
    final request = StreamController<StreamingRecognizeRequest>();

    // Send the streaming config at first.
    request.add(StreamingRecognizeRequest()..streamingConfig = config.toConfig());

    _audioStreamSubscription = audioStream.listen((audio) {
      // Add audio content when stream changes.
      request.add(StreamingRecognizeRequest()..audioContent = audio);
    });

    _audioStreamSubscription!.onDone(() {
      // Close the request stream, if the audio stream is finished.
      request.close();
    });
    return client.streamingRecognize(request.stream);
  }

  /// Sends a [LongRunningRecognizeRequest] request to the Google Speech Api.
  /// Requires a [RecognitionConfigBeta] and an [RecognitionAudio].
  ///
  /// To use asynchronous speech recognition to transcribe audio longer than 60
  /// seconds, you must have your data saved in a Google Cloud Storage bucket.
  ResponseFuture<Operation> longRunningRecognize(RecognitionConfig config, String audioGcsUri) {
    final client = SpeechClient(_channel, options: _options);

    // transform audio to RecognitionAudio
    final recognitionAudio = RecognitionAudio()..uri = audioGcsUri;

    // Create the request, which transmits the necessary
    // data to the Google Api.
    final request = (LongRunningRecognizeRequest()
      ..config = config.toConfig()
      ..audio = recognitionAudio);
    return client.longRunningRecognize(request);
  }

  Future<LongRunningRequestResult> pollingLongRunningRecognize(RecognitionConfig config, String audioGcsUri,
      {Duration pollInterval = const Duration(seconds: 1)}) async {
    final client = SpeechClient(_channel, options: _options);

    // transform audio to RecognitionAudio
    final recognitionAudio = RecognitionAudio()..uri = audioGcsUri;

    // Create the request, which transmits the necessary
    // data to the Google Api.
    final request = (LongRunningRecognizeRequest()
      ..config = config.toConfig()
      ..audio = recognitionAudio);
    final operation = await client.longRunningRecognize(request);
    return _pollOperation(operation, pollInterval);
  }

  Future<LongRunningRequestResult> _pollOperation(Operation operation, Duration pollInterval) async {
    final operationsClient = OperationsClient(_channel);
    late Operation operationResult;
    var isDone = false;
    while (isDone != true) {
      final currentOperation = await operationsClient.getOperation(GetOperationRequest(name: operation.name), options: _options);

      if (currentOperation.done) {
        isDone = true;
        operationResult = currentOperation;
      }

      await Future.delayed(pollInterval);
    }
    final response = LongRunningRecognizeResponse.fromBuffer(operationResult.response.value);

    final result = LongRunningRequestResult(
      operation: operationResult,
      results: response.results
          .map(
            (result) => TranscriptionResult(
              alternatives: result.alternatives
                  .map(
                    (alternative) => Transcript(
                      transcript: alternative.transcript,
                      confidence: alternative.confidence,
                      words: alternative.words,
                    ),
                  )
                  .toList(),
              resultEndOffset: ResultEndOffset(
                seconds: result.resultEndTime.seconds.toInt(),
                nanos: result.resultEndTime.nanos.toInt(),
              ),
              languageCode: result.languageCode,
            ),
          )
          .toList(),
      error: operationResult.error,
    );

    return result;
  }

  void dispose() {
    _audioStreamSubscription?.cancel();
  }
}
