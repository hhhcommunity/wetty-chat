import 'package:chahua/core/api/models/messages_api_models.dart';
import 'package:chahua/core/api/models/group_info_api_models.dart';
import 'package:chahua/core/api/services/pinned_messages_api_service.dart';
import 'package:chahua/core/preferences/app_preferences.dart';
import 'package:chahua/core/providers/shared_preferences_provider.dart';
import 'package:chahua/core/session/dev_session_store.dart';
import 'package:chahua/features/audio/application/audio_waveform_cache_service.dart';
import 'package:chahua/features/conversation/compose/application/audio_recorder_service.dart';
import 'package:chahua/features/conversation/compose/data/message_api_service_v2.dart';
import 'package:chahua/features/conversation/compose/presentation/composer_mention_autocomplete.dart';
import 'package:chahua/features/conversation/compose/presentation/conversation_v2_composer_bar.dart';
import 'package:chahua/features/conversation/compose/presentation/conversation_composer_view_model.dart';
import 'package:chahua/features/conversation/shared/domain/conversation_identity.dart';
import 'package:chahua/features/conversation/shared/domain/launch_request.dart';
import 'package:chahua/features/conversation/shared/presentation/conversation_surface_v2.dart';
import 'package:chahua/features/conversation/pins/domain/pinned_message.dart';
import 'package:chahua/features/groups/members/data/group_member_api_service.dart';
import 'package:chahua/features/groups/members/data/group_member_models.dart';
import 'package:chahua/features/groups/members/data/group_member_repository.dart';
import 'package:chahua/features/groups/metadata/data/group_metadata_api_service.dart';
import 'package:chahua/features/groups/metadata/data/group_metadata_repository.dart';
import 'package:chahua/features/shared/data/read_state_repository.dart';
import 'package:chahua/features/shared/model/message/message.dart';
import 'package:chahua/l10n/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationV2ComposerBar mention autocomplete', () {
    // Use case:
    // The user focuses the composer and types '@'. The mention picker should
    // appear after the debounce lookup without stealing focus from the input,
    // otherwise the user cannot continue composing from the keyboard.
    testWidgets('keeps input focused when mention suggestions appear', (
      tester,
    ) async {
      final members = _FakeGroupMemberRepository(_members);

      await _pumpComposer(tester, members: members);
      await _focusComposer(tester);

      await tester.enterText(find.byType(CupertinoTextField), '@');
      await _pumpMentionLookup(tester);

      expect(find.byType(ComposerMentionAutocomplete), findsOneWidget);
      expect(_composerInputHasFocus(tester), isTrue);
      _expectKeyboardVisible(tester);
      expect(members.queries, contains(''));
    });

    // Use case:
    // The mention picker is inserted above the composer. That insertion must
    // not replace the existing EditableText subtree; disposing it closes the
    // platform text-input client, which presents on device as the keyboard
    // disappearing even though the reused FocusNode still reports focus.
    testWidgets('preserves editable text state when suggestions appear', (
      tester,
    ) async {
      final members = _FakeGroupMemberRepository(_members);

      await _pumpComposer(tester, members: members);
      await _focusComposer(tester);
      final beforeSuggestions = tester.state<EditableTextState>(
        find.byType(EditableText),
      );

      await tester.enterText(find.byType(CupertinoTextField), '@');
      await _pumpMentionLookup(tester);

      final afterSuggestions = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(identical(afterSuggestions, beforeSuggestions), isTrue);
      _expectKeyboardVisible(tester);
    });

    // Use case:
    // The user keeps typing while the mention picker is already open. Narrowing
    // '@' to '@al' should keep the same text field focused and refresh the
    // suggestions instead of closing the keyboard/focus path mid-query.
    testWidgets('keeps input focused when typing narrows mention suggestions', (
      tester,
    ) async {
      final members = _FakeGroupMemberRepository(_members);

      await _pumpComposer(tester, members: members);
      await _focusComposer(tester);

      await tester.enterText(find.byType(CupertinoTextField), '@');
      await _pumpMentionLookup(tester);
      expect(_composerInputHasFocus(tester), isTrue);

      tester.testTextInput.enterText('@al');
      await tester.pump();
      await _pumpMentionLookup(tester);

      expect(_composerInputHasFocus(tester), isTrue);
      _expectKeyboardVisible(tester);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Alfred'), findsOneWidget);
      expect(find.text('Bob'), findsNothing);
      expect(members.queries, contains('al'));
    });

    // Use case:
    // After filtering the picker, the user taps a member. Selection should
    // replace the active @query with a display mention and immediately return
    // focus to the composer so typing can continue after the inserted space.
    testWidgets('keeps input focused after selecting a mention suggestion', (
      tester,
    ) async {
      final members = _FakeGroupMemberRepository(_members);

      await _pumpComposer(tester, members: members);
      await _focusComposer(tester);

      await tester.enterText(find.byType(CupertinoTextField), '@al');
      await _pumpMentionLookup(tester);
      await tester.tap(find.text('Alice'));
      await tester.pump();

      expect(_composerInputHasFocus(tester), isTrue);
      _expectKeyboardVisible(tester);
      expect(_composerText(tester), '@Alice ');
      expect(find.byType(ComposerMentionAutocomplete), findsNothing);
    });

    // Use case:
    // The full conversation surface has an outer tap handler that dismisses
    // transient composer UI. If the user taps back into the input while the
    // mention picker is open, that outer handler must not win and blur the
    // field before the user can continue narrowing the @query.
    testWidgets(
      'keeps input focused when tapping field while suggestions are open inside dismiss wrapper',
      (tester) async {
        final members = _FakeGroupMemberRepository(_members);

        await _pumpComposer(
          tester,
          members: members,
          wrapWithDismissGesture: true,
        );
        await _focusComposer(tester);

        await tester.enterText(find.byType(CupertinoTextField), '@');
        await _pumpMentionLookup(tester);
        expect(find.byType(ComposerMentionAutocomplete), findsOneWidget);

        await tester.tap(find.byType(CupertinoTextField));
        await tester.pump();
        tester.testTextInput.enterText('@al');
        await tester.pump();
        await _pumpMentionLookup(tester);

        expect(_composerInputHasFocus(tester), isTrue);
        _expectKeyboardVisible(tester);
        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Alfred'), findsOneWidget);
        expect(find.text('Bob'), findsNothing);
      },
    );

    // Use case:
    // This is the closest repro shape to the app screen: a full conversation
    // surface, a visible keyboard inset, timeline above the composer, and the
    // mention picker appearing as part of the bottom compose surface. Typing
    // '@' should not let the surface-level tap/focus plumbing blur the input.
    testWidgets(
      'keeps input focused when suggestions appear inside conversation surface with keyboard inset',
      (tester) async {
        final members = _FakeGroupMemberRepository(_members);

        await _pumpConversationSurface(
          tester,
          members: members,
          keyboardInset: 240,
        );
        await _settleSurface(tester);
        await _focusComposer(tester);

        await tester.enterText(find.byType(CupertinoTextField), '@');
        await _pumpMentionLookup(tester);

        expect(find.byType(ComposerMentionAutocomplete), findsOneWidget);
        expect(_composerInputHasFocus(tester), isTrue);
        _expectKeyboardVisible(tester);
        expect(members.queries, contains(''));
      },
    );

    // Use case:
    // On device the keyboard inset is introduced after the field takes focus.
    // This covers the timing where the user types '@' and the mention picker
    // appears during the same compose-surface layout transition as the keyboard.
    testWidgets(
      'keeps input focused when keyboard inset changes while mention suggestions appear',
      (tester) async {
        final members = _FakeGroupMemberRepository(_members);
        final keyboardInset = ValueNotifier<double>(0);
        addTearDown(keyboardInset.dispose);

        await _pumpConversationSurfaceWithKeyboard(
          tester,
          members: members,
          keyboardInset: keyboardInset,
        );
        await _settleSurface(tester);
        await _focusComposer(tester);

        await tester.enterText(find.byType(CupertinoTextField), '@');
        keyboardInset.value = 240;
        await tester.pump();
        await _pumpMentionLookup(tester);

        expect(find.byType(ComposerMentionAutocomplete), findsOneWidget);
        expect(_composerInputHasFocus(tester), isTrue);
        _expectKeyboardVisible(tester);
        expect(members.queries, contains(''));
      },
    );

    // Use case:
    // In the production screen, the full conversation surface owns a broad
    // background-tap dismiss gesture. When the user taps back into the composer
    // while the mention picker is open, the field should still keep the
    // platform keyboard connected so the next character narrows the picker.
    testWidgets(
      'keeps keyboard connected when retapping input inside full surface suggestions',
      (tester) async {
        final members = _FakeGroupMemberRepository(_members);

        await _pumpConversationSurface(
          tester,
          members: members,
          keyboardInset: 240,
        );
        await _settleSurface(tester);
        await _focusComposer(tester);

        await tester.enterText(find.byType(CupertinoTextField), '@');
        await _pumpMentionLookup(tester);
        expect(find.byType(ComposerMentionAutocomplete), findsOneWidget);

        await tester.tap(find.byType(CupertinoTextField));
        await tester.pump();
        tester.testTextInput.enterText('@al');
        await tester.pump();
        await _pumpMentionLookup(tester);

        expect(_composerInputHasFocus(tester), isTrue);
        _expectKeyboardVisible(tester);
        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Alfred'), findsOneWidget);
        expect(find.text('Bob'), findsNothing);
      },
    );
  });
}

const _identity = (chatId: 42, threadRootId: null);

const _members = <GroupMember>[
  GroupMember(uid: 1, username: 'Alice', role: 'member'),
  GroupMember(uid: 2, username: 'Bob', role: 'member'),
  GroupMember(uid: 3, username: 'Alfred', role: 'member'),
];

Future<void> _pumpComposer(
  WidgetTester tester, {
  required _FakeGroupMemberRepository members,
  bool wrapWithDismissGesture = false,
}) async {
  final composer = Align(
    alignment: Alignment.bottomCenter,
    child: ConversationV2ComposerBar(identity: _identity),
  );
  await tester.pumpWidget(
    _withProviders(
      members: members,
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: wrapWithDismissGesture
              ? GestureDetector(
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                  child: composer,
                )
              : composer,
        ),
      ),
    ),
  );
}

Future<void> _pumpConversationSurface(
  WidgetTester tester, {
  required _FakeGroupMemberRepository members,
  required double keyboardInset,
}) async {
  final keyboardInsetNotifier = ValueNotifier<double>(keyboardInset);
  addTearDown(keyboardInsetNotifier.dispose);
  await _pumpConversationSurfaceWithKeyboard(
    tester,
    members: members,
    keyboardInset: keyboardInsetNotifier,
  );
}

Future<void> _pumpConversationSurfaceWithKeyboard(
  WidgetTester tester, {
  required _FakeGroupMemberRepository members,
  required ValueListenable<double> keyboardInset,
}) async {
  await tester.pumpWidget(
    _withProviders(
      members: members,
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<double>(
          valueListenable: keyboardInset,
          builder: (context, inset, child) => MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 600),
              viewInsets: EdgeInsets.only(bottom: inset),
            ),
            child: child!,
          ),
          child: const SizedBox(
            width: 390,
            height: 600,
            child: ConversationSurfaceV2(
              identity: _identity,
              launchRequest: LaunchRequest.latest(),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _withProviders({
  required _FakeGroupMemberRepository members,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [
      authSessionProvider.overrideWith(_AuthenticatedSessionNotifier.new),
      sharedPreferencesProvider.overrideWithValue(
        AppPreferences.withData(const <String, Object>{}),
      ),
      groupMemberRepositoryProvider.overrideWithValue(members),
      groupMetadataRepositoryProvider.overrideWithValue(
        GroupMetadataRepository(_FakeGroupMetadataApiService()),
      ),
      pinnedMessagesApiServiceProvider.overrideWithValue(
        _FakePinnedMessagesApiService(),
      ),
      messageApiServiceV2Provider.overrideWithValue(_FakeMessageApiService()),
      audioRecorderServiceProvider.overrideWithValue(
        _FakeAudioRecorderService(),
      ),
      audioWaveformCacheServiceProvider.overrideWithValue(
        _FakeAudioWaveformCacheService(),
      ),
      readStateRepositoryProvider.overrideWith(_NoopReadStateRepository.new),
    ],
    child: child,
  );
}

Future<void> _focusComposer(WidgetTester tester) async {
  await tester.showKeyboard(find.byType(CupertinoTextField));
  await tester.pump();
  expect(_composerInputHasFocus(tester), isTrue);
  _expectKeyboardVisible(tester);
}

Future<void> _settleSurface(WidgetTester tester) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    await tester.pump();
    if (find.byType(CupertinoTextField).evaluate().isNotEmpty) {
      return;
    }
  }
  expect(find.byType(CupertinoTextField), findsOneWidget);
}

Future<void> _pumpMentionLookup(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

bool _composerInputHasFocus(WidgetTester tester) {
  final field = tester.widget<CupertinoTextField>(
    find.byType(CupertinoTextField),
  );
  return field.focusNode?.hasFocus ?? false;
}

bool _keyboardIsVisible(WidgetTester tester) {
  return tester.testTextInput.isVisible;
}

void _expectKeyboardVisible(WidgetTester tester) {
  expect(
    _keyboardIsVisible(tester),
    isTrue,
    reason: 'TextInput method log: ${_textInputMethodLog(tester)}',
  );
}

String _textInputMethodLog(WidgetTester tester) {
  return tester.testTextInput.log.map((call) => call.method).join(', ');
}

String _composerText(WidgetTester tester) {
  final field = tester.widget<CupertinoTextField>(
    find.byType(CupertinoTextField),
  );
  return field.controller?.text ?? '';
}

class _FakeGroupMemberRepository extends GroupMemberRepository {
  _FakeGroupMemberRepository(this.members)
    : super(GroupMemberApiService(Dio()));

  final List<GroupMember> members;
  final queries = <String?>[];

  @override
  Future<GroupMembersPage> fetchMembers(
    String chatId, {
    int limit = 50,
    int? after,
    String? query,
    GroupMemberSearchMode? searchMode,
  }) async {
    queries.add(query);
    final normalizedQuery = query?.toLowerCase().trim() ?? '';
    final filtered = normalizedQuery.isEmpty
        ? members
        : members
              .where(
                (member) => (member.username ?? '').toLowerCase().contains(
                  normalizedQuery,
                ),
              )
              .toList(growable: false);
    return GroupMembersPage(
      members: filtered.take(limit).toList(growable: false),
    );
  }
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
  Future<ListMessagesResponseDto> fetchConversationMessages(
    ConversationIdentity identity, {
    int? max,
    int? before,
    int? after,
    int? around,
  }) async {
    return ListMessagesResponseDto(messages: _messages(1, 3));
  }

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

class _FakeGroupMetadataApiService extends GroupMetadataApiService {
  _FakeGroupMetadataApiService() : super(Dio());

  @override
  Future<GroupInfoResponseDto> fetchGroupMetadata(String chatId) async {
    return GroupInfoResponseDto(
      id: int.parse(chatId),
      name: 'Test Chat',
      myRole: 'member',
    );
  }
}

class _FakePinnedMessagesApiService extends PinnedMessagesApiService {
  _FakePinnedMessagesApiService() : super(Dio());

  @override
  Future<List<PinnedMessage>> listPins(int chatId) async {
    return const <PinnedMessage>[];
  }
}

class _NoopReadStateRepository extends ReadStateRepository {
  _NoopReadStateRepository(super.ref);

  @override
  void reportVisibleMessageRead({
    required ConversationIdentity identity,
    required int messageId,
  }) {}
}

List<MessageItemDto> _messages(int start, int end) {
  return [for (var id = start; id <= end; id++) _message(id)];
}

MessageItemDto _message(int id) {
  return MessageItemDto(
    id: id,
    message: 'message $id',
    sender: const UserDto(uid: 7, name: 'Sender'),
    chatId: _identity.chatId,
    clientGeneratedId: 'client-$id',
  );
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
