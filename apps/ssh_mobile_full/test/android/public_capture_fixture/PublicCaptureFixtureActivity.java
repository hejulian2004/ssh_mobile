package com.example.ssh_mobile.test;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.os.Bundle;
import android.view.View;

/** Public moving pixels only; no permissions, files, SDK or network runtime. */
public final class PublicCaptureFixtureActivity extends Activity {
  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    setContentView(new FixtureView(this));
  }

  private static final class FixtureView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private boolean attached;

    FixtureView(Context context) {
      super(context);
      setLayerType(View.LAYER_TYPE_SOFTWARE, null);
    }

    @Override
    protected void onAttachedToWindow() {
      super.onAttachedToWindow();
      attached = true;
      invalidate();
    }

    @Override
    protected void onDetachedFromWindow() {
      attached = false;
      super.onDetachedFromWindow();
    }

    @Override
    protected void onDraw(Canvas canvas) {
      super.onDraw(canvas);
      final int width = getWidth();
      final int height = getHeight();
      canvas.drawColor(0xff126782);
      paint.setColor(0xff087f8c);
      canvas.drawRect(width / 2f, 0, width, height, paint);
      paint.setColor(0xffffffff);
      paint.setTextAlign(Paint.Align.CENTER);
      paint.setTextSize(22 * getResources().getDisplayMetrics().density);
      canvas.drawText("PUBLIC SCREEN SHARE TEST", width / 2f, height / 2f - 40, paint);
      canvas.drawText(width + " x " + height, width / 2f, height / 2f + 40, paint);
      final float position = (getDrawingTime() / 10) % Math.max(width, 1);
      paint.setColor(0xffffd166);
      canvas.drawRect(position, height * .7f, position + 80, height * .7f + 40, paint);
      if (attached) postInvalidateDelayed(100);
    }
  }
}
