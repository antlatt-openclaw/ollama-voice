"""WAV format helpers — header construction and PCM-to-WAV wrapping."""

import struct


def wav_header(data_length: int, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    byte_rate = sample_rate * channels * bits // 8
    block_align = channels * bits // 8
    return struct.pack(
        '<4sI4s4sIHHIIHH4sI',
        b'RIFF', data_length + 36, b'WAVE',
        b'fmt ', 16, 1, channels, sample_rate, byte_rate, block_align, bits,
        b'data', data_length,
    )


def pcm_to_wav(pcm_data: bytes, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    return wav_header(len(pcm_data), sample_rate, channels, bits) + pcm_data
