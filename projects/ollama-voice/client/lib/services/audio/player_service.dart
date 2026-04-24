import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';

class PlayerService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription? _playerStateSub;
  StreamSubscription? _audioSessionSub;
  Timer? _playbackEndTimer;

  ConcatenatingAudioSource? _playlist;
  bool _playlistActive = false;

  final List<Uint8List> _pcmChunks = [];
  int _audioBufferLength = 0;
  // Hard limit per sentence — prevents unbounded growth if audioEnd is missed.
  static const int _maxBufferBytes = 5 * 1024 * 1024; // 5 MB

  static const int _outputSampleRate = 24000;
  // Delay before re-enabling mic after playback ends (prevents echo)
  static const int _micReenableDelayMs = 200;

  bool _isInitialized = false;
  bool _isInterrupted = false;
  bool _isMuted = false;
  bool _autoPlay = true; // Auto-play responses by default in hands-free mode
  double _speed = 1.0;

  // ── Audio routing ────────────────────────────────────────────────────────
  // When true, route audio to earpiece instead of speaker (proximity sensor).
  bool _useEarpiece = false;

  // ── Playback completion tracking ─────────────────────────────────────────
  final StreamController<bool> _playbackCompleteStream = StreamController.broadcast();

  bool get isPlaying => _player.playing;
  bool get isMuted => _isMuted;
  bool get autoPlay => _autoPlay;
  double get speed => _speed;
  bool get useEarpiece => _useEarpiece;

  /// Stream that emits true when playback completes naturally (all sentences done).
  Stream<bool> get playbackCompleteStream => _playbackCompleteStream.stream;

  /// Callback invoked after playback ends + mic re-enable delay (for hands-free mode).
  VoidCallback? onPlaybackEnded;

  Future<void> init() async {
    if (_isInitialized) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    _audioSessionSub = session.interruptionEventStream.listen((_) {
      // Handle audio interruptions (e.g., phone calls)
      _configureAudioSession();
    });

    _playerStateSub?.cancel();
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _player.stop();
        _playlist = null;
        _playlistActive = false;
        if (!_playbackCompleteStream.isClosed) {
          _playbackCompleteStream.add(true);
        }
      }
      // When playback stops (naturally or by user), schedule mic re-enable.
      if (!state.playing && _playbackEndTimer == null && !_isInterrupted) {
        _playbackEndTimer = Timer(
          const Duration(milliseconds: _micReenableDelayMs),
          () {
            _playbackEndTimer = null;
            onPlaybackEnded?.call();
          },
        );
      }
      notifyListeners();
    });
    _isInitialized = true;
  }

  /// Configure audio session based on current routing settings.
  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    if (_useEarpiece) {
      await session.configure(const AudioSessionConfiguration.speech().copyWith(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
      ));
    } else {
      await session.configure(const AudioSessionConfiguration.speech());
    }
  }

  /// Enable/disable auto-play. In hands-free mode, this should be true.
  void setAutoPlay(bool value) {
    _autoPlay = value;
    notifyListeners();
  }

  /// Route audio to earpiece (true) or speaker (false).
  void setUseEarpiece(bool value) {
    _useEarpiece = value;
    _configureAudioSession();
    notifyListeners();
  }

  // ── WAV helpers ───────────────────────────────────────────────────────────

  Uint8List _wrapInWavHeader(Uint8List pcmData, int sampleRate, int channels) {
    assert(sampleRate > 0 && channels > 0, 'Invalid audio parameters');
    final byteRate = sampleRate * channels * 2;
    final dataSize = pcmData.length;
    final header = Uint8List(44);
    final view = ByteData.view(header.buffer);
    _setStr(header, 0, 'RIFF');
    view.setUint32(4, dataSize + 36, Endian.little);
    _setStr(header, 8, 'WAVE');
    _setStr(header, 12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, 1, Endian.little);
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, channels * 2, Endian.little);
    view.setUint16(34, 16, Endian.little);
    _setStr(header, 36, 'data');
    view.setUint32(40, dataSize, Endian.little);
    return Uint8List.fromList([...header, ...pcmData]);
  }

  void _setStr(Uint8List buf, int offset, String s) {
    for (int i = 0; i < s.length; i++) buf[offset + i] = s.codeUnitAt(i);
  }

  // ── Response lifecycle ────────────────────────────────────────────────────

  Future<void> startResponse() async {
    _playbackEndTimer?.cancel();
    _playbackEndTimer = null;
    _isInterrupted = false;
    await _player.stop();
    _playlist = ConcatenatingAudioSource(children: []);
    _playlistActive = false;
    _pcmChunks.clear();
    _audioBufferLength = 0;
  }

  void startSentence() {
    _pcmChunks.clear();
    _audioBufferLength = 0;
  }

  void bufferChunk(Uint8List data) {
    if (_isInterrupted) return;
    if (_audioBufferLength + data.length > _maxBufferBytes) {
      print('[Player] Audio buffer limit reached (${_maxBufferBytes ~/ 1024}KB), dropping chunk');
      return;
    }
    _pcmChunks.add(data);
    _audioBufferLength += data.length;
  }

  /// Play buffered audio. If [autoPlay] is false, the audio is buffered but
  /// not played until [playBuffered] is called explicitly or autoPlay is enabled.
  Future<void> playBuffered() async {
    if (!_isInitialized || _audioBufferLength == 0 || _isInterrupted) return;
    if (!_autoPlay) return;

    final allPcm = Uint8List(_audioBufferLength);
    int offset = 0;
    for (final chunk in _pcmChunks) {
      allPcm.setAll(offset, chunk);
      offset += chunk.length;
    }
    _pcmChunks.clear();
    _audioBufferLength = 0;

    const silenceBytes = _outputSampleRate * 2 * 350 ~/ 1000;
    final withSilence = Uint8List(allPcm.length + silenceBytes);
    withSilence.setAll(0, allPcm);

    final wavData = _wrapInWavHeader(withSilence, _outputSampleRate, 1);

    final tempDir = await _getAudioTempDir();
    await _cleanOldTempFiles(tempDir);
    final tempFile = File(
        '${tempDir.path}/vr_${DateTime.now().millisecondsSinceEpoch}.wav');
    await tempFile.writeAsBytes(wavData);

    if (_isInterrupted) return;

    _playlist ??= ConcatenatingAudioSource(children: []);
    final newIdx = _playlist!.length;
    await _playlist!.add(AudioSource.file(tempFile.path));

    if (!_playlistActive) {
      _playlistActive = true;
      await _player.setAudioSource(_playlist!);
      await _player.setSpeed(_speed);
      await _player.setVolume(_isMuted ? 0.0 : 1.0);
      await _player.play();
    } else if (!_player.playing) {
      await _player.seek(Duration.zero, index: newIdx);
      await _player.play();
    }
  }

  // ── Playback controls ─────────────────────────────────────────────────────

  Future<void> setSpeed(double s) async {
    _speed = s;
    await _player.setSpeed(s);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    await _player.setVolume(_isMuted ? 0.0 : 1.0);
    notifyListeners();
  }

  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    }
  }

  Future<void> replayFromStart() async {
    if (_playlist == null) return;
    await _player.seek(Duration.zero, index: 0);
    if (!_player.playing) await _player.play();
  }

  // ── Interrupt / stop ──────────────────────────────────────────────────────

  Future<void> interrupt() async {
    _isInterrupted = true;
    _playbackEndTimer?.cancel();
    _playbackEndTimer = null;
    await _player.stop();
    _playlist = null;
    _playlistActive = false;
    _pcmChunks.clear();
    _audioBufferLength = 0;
    // Clean temp WAV files on interrupt too (not just on next playBuffered)
    try {
      final tempDir = await _getAudioTempDir();
      await _cleanOldTempFiles(tempDir);
    } catch (_) {}
    // _isInterrupted stays true until startResponse() clears it, preventing
    // any late-arriving audio chunks from replaying after the interrupt.
  }

  Future<void> stop() async {
    await _player.stop();
    _playlist = null;
    _playlistActive = false;
    _pcmChunks.clear();
    _audioBufferLength = 0;
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  /// Get or create a dedicated subdirectory for audio temp files.
  Future<Directory> _getAudioTempDir() async {
    final baseTemp = await getTemporaryDirectory();
    final dir = Directory('${baseTemp.path}/vr_audio');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<void> _cleanOldTempFiles(Directory tempDir) async {
    try {
      final files = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('vr_'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (var i = 20; i < files.length; i++) {
        await files[i].delete();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _audioSessionSub?.cancel();
    _playbackEndTimer?.cancel();
    _playbackEndTimer = null;
    _player.dispose();
    _playbackCompleteStream.close();
    super.dispose();
  }
}
