import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';

class PlayerService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription? _playerStateSub;

  ConcatenatingAudioSource? _playlist;
  bool _playlistActive = false;

  final List<Uint8List> _pcmChunks = [];
  int _audioBufferLength = 0;
  // Hard limit per sentence — prevents unbounded growth if audioEnd is missed.
  static const int _maxBufferBytes = 5 * 1024 * 1024; // 5 MB

  static const int _outputSampleRate = 24000;

  bool _isInitialized = false;
  bool _isInterrupted = false;
  bool _isMuted = false;
  double _speed = 1.0;

  bool get isPlaying => _player.playing;
  bool get isMuted => _isMuted;
  double get speed => _speed;

  Future<void> init() async {
    if (_isInitialized) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    _playerStateSub?.cancel();
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // Playlist finished naturally — reset so the PTT button returns to idle.
        _player.stop();
        _playlist = null;
        _playlistActive = false;
      }
      notifyListeners();
    });
    _isInitialized = true;
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

  Future<void> playBuffered() async {
    if (!_isInitialized || _audioBufferLength == 0 || _isInterrupted) return;

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
    _player.dispose();
    super.dispose();
  }
}
