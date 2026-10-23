package com.hejulian.realtime_media_android.test;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import java.util.Locale;

/** Device-only capability metadata. Does not capture or read application data. */
public final class EncoderCapabilityProbe {
  public static void main(String[] args) {
    boolean hardware = false;
    boolean software = false;
    for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
      if (!info.isEncoder()) continue;
      boolean avc = false;
      for (String type : info.getSupportedTypes()) {
        avc |= "video/avc".equalsIgnoreCase(type);
      }
      if (!avc) continue;
      final String name = info.getName().toLowerCase(Locale.ROOT);
      final boolean softwareOnly = Build.VERSION.SDK_INT >= 29 ? info.isSoftwareOnly()
          : name.startsWith("omx.google.") || name.startsWith("c2.android.");
      software |= softwareOnly;
      hardware |= Build.VERSION.SDK_INT >= 29 ? info.isHardwareAccelerated() : !softwareOnly;
    }
    System.out.println("ENCODER_CAPABILITY hardware_h264=" + hardware + " software_h264=" + software);
  }
}
