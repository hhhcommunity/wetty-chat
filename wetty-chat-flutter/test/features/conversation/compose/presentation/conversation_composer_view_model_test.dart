import 'dart:async';

import 'package:chahua/core/api/models/messages_api_models.dart';
import 'package:chahua/core/session/current_user_profile.dart';
import 'package:chahua/core/session/dev_session_store.dart';
import 'package:chahua/features/audio/application/audio_waveform_cache_service.dart';
import 'package:chahua/features/conversation/compose/application/audio_recorder_service.dart';
import 'package:chahua/features/conversation/compose/data/message_api_service_v2.dart';
import 'package:chahua/features/conversation/compose/presentation/conversation_composer_view_model.dart';
import 'package:chahua/features/conversation/shared/application/conversation_canonical_message_store.dart';
import 'package:chahua/features/conversation/shared/domain/conversation_identity.dart';
import 'package:chahua/features/shared/model/message/message.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('optimistic text send uses current user profile sender', () async {
    final api = _FakeMessageApiService();
    final container = _container(
      api: api,
      profile: Future<CurrentUserProfile?>.value(
        const CurrentUserProfile(
          uid: 42,
          username: 'Alice',
          avatarUrl: 'https://example.com/alice.png',
          gender: 1,
        ),
      ),
    );
    addTearDown(container.dispose);
    await container.read(currentUserProfileProvider.future);

    await container
        .read(conversationComposerViewModelProvider(_identity).notifier)
        .send(text: 'Hello');

    final message = _singleOptimisticMessage(container);
    expect(message.sender.uid, 42);
    expect(message.sender.name, 'Alice');
    expect(message.sender.avatarUrl, 'https://example.com/alice.png');
    expect(message.sender.gender, 1);
  });

  test('optimistic text send falls back while profile is loading', () async {
    final api = _FakeMessageApiService();
    final pendingProfile = Completer<CurrentUserProfile?>();
    final container = _container(api: api, profile: pendingProfile.future);
    addTearDown(container.dispose);

    await container
        .read(conversationComposerViewModelProvider(_identity).notifier)
        .send(text: 'Hello');

    final message = _singleOptimisticMessage(container);
    expect(message.sender.uid, 42);
    expect(message.sender.name, 'User 42');
    expect(message.sender.avatarUrl, isNull);
    expect(message.sender.gender, 0);

    pendingProfile.complete(null);
  });
}

const _identity = (chatId: 42, threadRootId: null);

ProviderContainer _container({
  required _FakeMessageApiService api,
  required Future<CurrentUserProfile?> profile,
}) {
  return ProviderContainer(
    overrides: [
      authSessionProvider.overrideWith(_AuthenticatedSessionNotifier.new),
      currentUserProfileProvider.overrideWith((ref) => profile),
      messageApiServiceV2Provider.overrideWithValue(api),
      audioRecorderServiceProvider.overrideWithValue(
        _FakeAudioRecorderService(),
      ),
      audioWaveformCacheServiceProvider.overrideWithValue(
        _FakeAudioWaveformCacheService(),
      ),
    ],
  );
}

ConversationMessageV2 _singleOptimisticMessage(ProviderContainer container) {
  final scope = container.read(
    conversationTimelineMessageStoreProvider,
  )[_identity];
  expect(scope, isNotNull);
  expect(scope!.optimisticMessages, hasLength(1));
  return scope.optimisticMessages.single;
}

class _AuthenticatedSessionNotifier extends AuthSessionNotifier {
  @override
  AuthSessionState build() {
    return const AuthSessionState(
      status: AuthBootstrapStatus.authenticated,
      mode: AuthSessionMode.devHeader,
      developerUserId: 42,
      currentUserId: 42,
    );
  }
}

class _FakeMessageApiService extends MessageApiServiceV2 {
  _FakeMessageApiService() : super(Dio(), 42);

  @override
  Future<MessageItemDto> sendConversationMessage(
    ConversationIdentity identity,
    String text, {
    required String messageType,
    int? replyToId,
    List<String> attachmentIds = const <String>[],
    required String clientGeneratedId,
    String? stickerId,
  }) async {
    return MessageItemDto(
      id: 100,
      message: text,
      messageType: messageType,
      sender: const UserDto(uid: 42, name: 'Alice'),
      chatId: identity.chatId,
      clientGeneratedId: clientGeneratedId,
    );
  }
}

class _FakeAudioRecorderService implements AudioRecorderService {
  @override
  Future<void> cancel() => Future<void>.value();

  @override
  Future<void> dispose() => Future<void>.value();

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isRecording() async => false;

  @override
  Future<void> start() => Future<void>.value();

  @override
  Future<RecordedAudioFile?> stop({required Duration duration}) async => null;
}

class _FakeAudioWaveformCacheService implements AudioWaveformCacheService {
  @override
  void clearMemory() {}

  @override
  Future<AudioWaveformSnapshot?> primeFromAttachmentMetadata({
    required String attachmentId,
    required Duration duration,
    required List<int> samples,
  }) async {
    return null;
  }

  @override
  Future<AudioWaveformSnapshot?> primeFromLocalRecording({
    required String attachmentId,
    required String audioFilePath,
    required Duration duration,
  }) async {
    return null;
  }

  @override
  Future<AudioWaveformSnapshot?> resolveForAttachment(
    AttachmentItem attachment, {
    Duration? preferredDuration,
    String? waveformInputPath,
  }) async {
    return null;
  }
}
