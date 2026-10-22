package com.hejulian.realtime_media_android;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.SystemClock;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.io.ByteArrayOutputStream;

/** Native-platform probe: accepts only a synthetic test access unit, not a screen. */
public final class DecoderSingleFrameProbe {
  public static void main(String[] args) throws Exception {
    byte[] frame = Files.readAllBytes(Paths.get(args[0]));
    byte[] config = parameterSets(frame);
    run(frame, config, false, 1, false);
    run(frame, config, true, 1, false);
    run(frame, config, false, 8, false);
    run(frame, config, false, 1, true);
    System.exit(0);
  }

  private static void run(byte[] frame, byte[] config, boolean lowLatency, int inputs,
      boolean flushAtEnd)
      throws Exception {
    MediaCodec codec = MediaCodec.createByCodecName("c2.android.avc.decoder");
    try {
      MediaFormat format = MediaFormat.createVideoFormat("video/avc", 16, 16);
      if (lowLatency) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
      codec.configure(format, null, null, 0);
      codec.start();
      int submitted = 0;
      int outputs = 0;
      boolean endQueued = !flushAtEnd;
      MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      long deadline = SystemClock.elapsedRealtime() + 2500;
      while (SystemClock.elapsedRealtime() < deadline) {
        if (submitted <= inputs) {
          int input = codec.dequeueInputBuffer(10000);
          if (input >= 0) {
            ByteBuffer buffer = codec.getInputBuffer(input);
            byte[] bytes = submitted == 0 ? config : frame;
            buffer.clear();
            buffer.put(bytes);
            codec.queueInputBuffer(input, 0, bytes.length, submitted * 100000L,
                submitted == 0 ? MediaCodec.BUFFER_FLAG_CODEC_CONFIG
                    : MediaCodec.BUFFER_FLAG_KEY_FRAME);
            ++submitted;
          }
        } else if (!endQueued) {
          int input = codec.dequeueInputBuffer(10000);
          if (input >= 0) {
            codec.queueInputBuffer(input, 0, 0, 900000L, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            endQueued = true;
          }
        }
        int output = codec.dequeueOutputBuffer(info, 10000);
        if (output >= 0) {
          codec.releaseOutputBuffer(output, false);
          if (info.size > 0) ++outputs;
        }
      }
      System.out.println("PROBE lowLatency=" + lowLatency + " inputs=" + (submitted - 1)
          + " flushAtEnd=" + flushAtEnd + " outputs=" + outputs);
      if (flushAtEnd && outputs == 0) {
        throw new IllegalStateException("Synthetic fixture did not decode after EOS");
      }
    } finally {
      try { codec.stop(); } finally { codec.release(); }
    }
  }

  private static byte[] parameterSets(byte[] frame) {
    ByteArrayOutputStream config = new ByteArrayOutputStream();
    for (int index = 0; index + 4 < frame.length; ++index) {
      int prefix = startCode(frame, index);
      if (prefix == 0) continue;
      int header = index + prefix;
      int end = header + 1;
      while (end + 3 <= frame.length && startCode(frame, end) == 0) ++end;
      if (end + 3 > frame.length) end = frame.length;
      int type = frame[header] & 31;
      if (type == 7 || type == 8) {
        config.write(new byte[] {0, 0, 0, 1}, 0, 4);
        config.write(frame, header, end - header);
      }
      index = end - 1;
    }
    if (config.size() == 0) throw new IllegalArgumentException("Missing fixture parameter sets");
    return config.toByteArray();
  }

  private static int startCode(byte[] frame, int index) {
    if (index + 3 > frame.length || frame[index] != 0 || frame[index + 1] != 0) return 0;
    if (frame[index + 2] == 1) return 3;
    return index + 4 <= frame.length && frame[index + 2] == 0 && frame[index + 3] == 1 ? 4 : 0;
  }
}
