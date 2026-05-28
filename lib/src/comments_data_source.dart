import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_chunk.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/load_asset.dart'
    if (dart.library.js_interop) 'package:chatscrollview/src/load_asset_web.dart'
    if (dart.library.io) 'package:chatscrollview/src/load_asset_native.dart';

/// Manifest for asset-based chat data.
class CommentsManifest {
  CommentsManifest._({
    required this.title,
    required this.totalMessages,
    required this.chunkSize,
    required this.chunks,
    required this.senders,
  });

  factory CommentsManifest.fromJson(Map<String, Object?> json) => CommentsManifest._(
    title: json['title']! as String,
    totalMessages: json['totalMessages']! as int,
    chunkSize: json['chunkSize']! as int,
    chunks: (json['chunks']! as List<Object?>).cast<String>(),
    senders: (json['senders']! as List<Object?>).cast<String>(),
  );

  final String title;
  final int totalMessages;
  final int chunkSize;
  final List<String> chunks;
  final List<String> senders;
}

/// Data source that loads pre-chunked JSON assets (e.g. GitHub issues).
///
/// Each chunk file contains up to [ChatScrollChunk.kSize] messages as JSON:
/// ```json
/// [{"id": 0, "sender": "user", "content": "...", "createdAt": "..."}]
/// ```
class CommentsDataSource extends ChatDataSource {
  CommentsDataSource._({
    required this.manifest,
    required this.assetPrefix,
    required this.fetchDelay,
    required this.maxCachedChunks,
  }) {
    final total = manifest.totalMessages;
    if (total > 0) {
      seedBoundaries(
        oldestKnownId: 0,
        newestKnownId: total - 1,
        reachedOldest: true,
        reachedNewest: true,
      );
    }
  }

  /// Load manifest and return a ready-to-use data source.
  static Future<CommentsDataSource> load({
    String assetPrefix = 'assets/comments',
    Duration fetchDelay = const Duration(milliseconds: 120),
    int maxCachedChunks = 32,
  }) async {
    final raw = await _loadString('$assetPrefix/manifest.json');
    final json = jsonDecode(raw) as Map<String, Object?>;
    final manifest = CommentsManifest.fromJson(json);
    return CommentsDataSource._(
      manifest: manifest,
      assetPrefix: assetPrefix,
      fetchDelay: fetchDelay,
      maxCachedChunks: maxCachedChunks,
    );
  }

  /// On native — loads from bundled assets via rootBundle.
  /// On web — fetches on demand via HTTP (assets excluded from service worker).
  static Future<String> _loadString(String assetPath) =>
      loadAsset(assetPath);

  final CommentsManifest manifest;
  final String assetPrefix;
  final Duration fetchDelay;

  /// Upper bound on retained parsed chunks. Excess entries are evicted in
  /// least-recently-used order so the cache cannot grow unbounded.
  final int maxCachedChunks;

  /// LRU cache of parsed asset chunks (insertion order = access order).
  final LinkedHashMap<int, List<IChatMessage>> _chunkCache =
      LinkedHashMap<int, List<IChatMessage>>();

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    // Simulate network delay.
    await Future<void>.delayed(fetchDelay);

    // Empty manifest — no messages to serve.
    if (manifest.totalMessages <= 0) return const [];

    final lo = fromId.clamp(0, manifest.totalMessages - 1);
    final hi = toId.clamp(0, manifest.totalMessages - 1);

    // Determine which asset chunks we need.
    final firstAssetChunk = lo ~/ manifest.chunkSize;
    final lastAssetChunk = hi ~/ manifest.chunkSize;

    final result = <IChatMessage>[];

    for (var ac = firstAssetChunk; ac <= lastAssetChunk; ac++) {
      final messages = await _loadAssetChunk(ac);
      for (final msg in messages) {
        if (msg.id >= lo && msg.id <= hi) result.add(msg);
      }
    }

    return result;
  }

  Future<List<IChatMessage>> _loadAssetChunk(int assetChunkIndex) async {
    // Cache hit — re-promote to most-recently-used.
    final cached = _chunkCache.remove(assetChunkIndex);
    if (cached != null) {
      _chunkCache[assetChunkIndex] = cached;
      return cached;
    }

    if (assetChunkIndex >= manifest.chunks.length) return const [];

    final fileName = manifest.chunks[assetChunkIndex];
    final raw = await _loadString('$assetPrefix/$fileName');
    final list = (jsonDecode(raw) as List<Object?>).cast<Map<String, Object?>>();

    final baseTime = DateTime.now();
    final messages = <IChatMessage>[
      for (final item in list)
        UserChatMessage(
          id: item['id']! as int,
          sender: item['sender']! as String,
          createdAt: DateTime.tryParse(item['createdAt'] as String? ?? '') ??
              baseTime,
          updatedAt: DateTime.tryParse(item['createdAt'] as String? ?? '') ??
              baseTime,
          content: item['content'] as String? ?? '',
        ),
    ];

    _chunkCache[assetChunkIndex] = messages;
    // Evict least-recently-used entries until within bound.
    while (_chunkCache.length > maxCachedChunks) {
      _chunkCache.remove(_chunkCache.keys.first);
    }
    return messages;
  }
}
