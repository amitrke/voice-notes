package com.subnext.voicenotes

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes any audio file Android can play (m4a/AAC, mp3, ogg, flac, ...) to a
 * 16 kHz mono 16-bit WAV, the format Sarvam's instant endpoint handles best.
 */
object AudioConverter {
    private const val TARGET_RATE = 16000

    fun toWav16kMono(src: String, dest: String) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(src)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    track = i
                    format = f
                    break
                }
            }
            if (track < 0 || format == null) throw IllegalArgumentException("No audio track")
            extractor.selectTrack(track)

            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            RandomAccessFile(dest, "rw").use { file ->
                file.setLength(0)
                file.write(ByteArray(44)) // header, patched once the size is known
                val sink = PcmSink(file)
                var inRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var float = false
                var resampler = Resampler(inRate, sink)

                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                while (!outputDone) {
                    if (!inputDone) {
                        val ib = codec.dequeueInputBuffer(10_000)
                        if (ib >= 0) {
                            val buf = codec.getInputBuffer(ib)!!
                            val n = extractor.readSampleData(buf, 0)
                            if (n < 0) {
                                codec.queueInputBuffer(
                                    ib, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(ib, 0, n, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val ob = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        ob >= 0 -> {
                            val buf = codec.getOutputBuffer(ob)!!
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            decode(buf, channels, float, resampler)
                            codec.releaseOutputBuffer(ob, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                outputDone = true
                            }
                        }
                        ob == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val out = codec.outputFormat
                            channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            val rate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            if (rate != inRate) {
                                inRate = rate
                                resampler = Resampler(inRate, sink)
                            }
                            float = out.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                out.getInteger(MediaFormat.KEY_PCM_ENCODING) ==
                                android.media.AudioFormat.ENCODING_PCM_FLOAT
                        }
                    }
                }
                sink.flush()
                writeHeader(file, sink.bytes)
            }
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            extractor.release()
        }
    }

    private fun decode(buf: ByteBuffer, channels: Int, float: Boolean, r: Resampler) {
        buf.order(ByteOrder.LITTLE_ENDIAN)
        val bytesPerSample = if (float) 4 else 2
        val frames = buf.remaining() / (bytesPerSample * channels)
        repeat(frames) {
            var sum = 0f
            repeat(channels) {
                sum += if (float) buf.getFloat() else buf.getShort() / 32768f
            }
            r.push(sum / channels)
        }
    }

    private fun writeHeader(file: RandomAccessFile, pcmBytes: Long) {
        val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()).putInt((36 + pcmBytes).toInt())
        h.put("WAVE".toByteArray()).put("fmt ".toByteArray()).putInt(16)
        h.putShort(1).putShort(1).putInt(TARGET_RATE).putInt(TARGET_RATE * 2)
        h.putShort(2).putShort(16)
        h.put("data".toByteArray()).putInt(pcmBytes.toInt())
        file.seek(0)
        file.write(h.array())
    }

    /** Buffers 16-bit little-endian samples and appends them to [file]. */
    private class PcmSink(private val file: RandomAccessFile) {
        private val buf = ByteArray(64 * 1024)
        private var n = 0
        var bytes = 0L
            private set

        fun put(sample: Float) {
            val v = (sample * 32767f).coerceIn(-32768f, 32767f).toInt()
            buf[n++] = v.toByte()
            buf[n++] = (v shr 8).toByte()
            bytes += 2
            if (n == buf.size) flush()
        }

        fun flush() {
            if (n > 0) file.write(buf, 0, n)
            n = 0
        }
    }

    /**
     * Streaming area-averaging resampler to 16 kHz. Averaging over each output
     * sample's span doubles as the low-pass filter that avoids aliasing.
     */
    private class Resampler(inRate: Int, private val sink: PcmSink) {
        private val step = inRate.toDouble() / TARGET_RATE
        private var acc = 0.0
        private var filled = 0.0

        fun push(x: Float) {
            var remain = 1.0
            while (true) {
                val need = step - filled
                if (remain >= need) {
                    acc += x * need
                    sink.put((acc / step).toFloat())
                    acc = 0.0
                    filled = 0.0
                    remain -= need
                    if (remain <= 1e-9) return
                } else {
                    acc += x * remain
                    filled += remain
                    return
                }
            }
        }
    }
}
