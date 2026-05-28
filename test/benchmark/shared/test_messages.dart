import 'dart:math';

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';

/// Preset message counts for benchmarks.
const int kSmall = 32;
const int kMedium = 256;
const int kLarge = 6000;

/// Short phrases used to build deterministic message content.
const _shortPhrases = [
  'Hello!',
  'Sure thing.',
  'Got it, thanks.',
  'On my way.',
  'Sounds good.',
  'OK',
  'Yes',
  'No problem',
  'See you later!',
  'BRB',
];

const _mediumPhrases = [
  'The quick brown fox jumps over the lazy dog near the riverbank.',
  'I was thinking we could meet up tomorrow at the coffee shop downtown.',
  'Can you send me the latest version of the document when you get a chance?',
  'The weather has been really unpredictable lately, hard to plan anything.',
  'Just finished reading that book you recommended — it was fantastic!',
  'We should probably discuss the project timeline before the meeting.',
  'I made some changes to the code, let me know if it looks good to you.',
  'The restaurant on 5th avenue has amazing pasta, we should go sometime.',
];

const _longPhrases = [
  'The first rule of Fight Club is: you do not talk about Fight Club. '
      'The second rule of Fight Club is: you DO NOT talk about Fight Club! '
      'Third rule of Fight Club: if someone yells "stop!", goes limp, '
      'or taps out, the fight is over. Fourth rule: only two guys to a fight.',
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
      'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
      'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea '
      'commodo consequat. Duis aute irure dolor in reprehenderit in voluptate '
      'velit esse cillum dolore eu fugiat nulla pariatur.',
  'According to all known laws of aviation, there is no way a bee should be '
      'able to fly. Its wings are too small to get its fat little body off the '
      'ground. The bee, of course, flies anyway because bees do not care what '
      'humans think is impossible. Yellow, black. Yellow, black.',
  'In the beginning the Universe was created. This has made a lot of people '
      'very angry and been widely regarded as a bad move. Many were '
      'increasingly of the opinion that they had all made a big mistake in '
      'coming down from the trees in the first place.',
];

/// Generate [count] deterministic test messages with varied content lengths.
///
/// Distribution: ~30% short, ~50% medium, ~20% long.
/// Uses `Random(42)` for reproducibility.
List<IChatMessage> generateMessages(int count) {
  final rng = Random(42);
  final now = DateTime(2026, 1, 1);
  final messages = <IChatMessage>[];

  for (var i = 0; i < count; i++) {
    final time = now.add(Duration(minutes: i));
    final roll = rng.nextDouble();

    final String content;
    if (roll < 0.3) {
      content = _shortPhrases[rng.nextInt(_shortPhrases.length)];
    } else if (roll < 0.8) {
      content = _mediumPhrases[rng.nextInt(_mediumPhrases.length)];
    } else {
      content = _longPhrases[rng.nextInt(_longPhrases.length)];
    }

    messages.add(
      UserChatMessage(
        id: i,
        sender: 'User',
        createdAt: time,
        updatedAt: time,
        content: content,
      ),
    );
  }
  return messages;
}

