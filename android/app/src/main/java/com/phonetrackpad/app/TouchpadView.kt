package com.phonetrackpad.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import kotlin.math.roundToInt

/**
 * Full-screen touch surface. Streams every touch sample (including batched
 * history) to the Mac as millimetres; the Mac does all gesture recognition.
 */
class TouchpadView(
    context: Context,
    private val onFrame: (body: String, lift: Boolean) -> Unit,
    private val onFiveFingerTap: () -> Unit,
) : View(context) {

    var status = ""
        set(value) { field = value; invalidate() }

    private val dm = resources.displayMetrics
    private val mmPerPx = 25.4f / ((dm.xdpi + dm.ydpi) / 2f)
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(40, 160, 190, 255) }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(110, 220, 220, 230)
        textSize = 14f * dm.scaledDensity
        textAlign = Paint.Align.CENTER
    }
    private val hintPaint = Paint(textPaint).apply { color = Color.argb(70, 220, 220, 230); textSize = 12f * dm.scaledDensity }
    private val sb = StringBuilder(256)
    private var fiveStart = -1L
    private var lastEvent: MotionEvent? = null

    init {
        setBackgroundColor(Color.rgb(11, 11, 15))
        isHapticFeedbackEnabled = false
        // Deliver touches as they arrive instead of batching them to the next frame.
        requestUnbufferedDispatch(InputDevice.SOURCE_TOUCHSCREEN)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        // Ask Android not to treat side swipes as Back (it honours up to 200dp per edge).
        val edge = (24 * dm.density).toInt()
        val band = (200 * dm.density).toInt()
        val h = b - t
        val top = ((h - band) / 2).coerceAtLeast(0)
        val bottom = (top + band).coerceAtMost(h)
        systemGestureExclusionRects = listOf(Rect(0, top, edge, bottom), Rect(r - l - edge, top, r - l, bottom))
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        for (h in 0 until e.historySize) emit(e, e.getHistoricalEventTime(h), h, -1)
        val skip = when (e.actionMasked) {
            MotionEvent.ACTION_POINTER_UP -> e.actionIndex
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> ALL
            else -> -1
        }
        emit(e, e.eventTime, -1, skip)
        detectFiveFingerTap(e)
        lastEvent?.recycle()
        lastEvent = if (skip == ALL) null else MotionEvent.obtain(e)
        invalidate()
        return true
    }

    private fun emit(e: MotionEvent, time: Long, h: Int, skip: Int) {
        val count = if (skip == ALL) 0 else e.pointerCount - if (skip >= 0) 1 else 0
        sb.setLength(0)
        sb.append(time).append(' ').append(count)
        if (skip != ALL) {
            for (i in 0 until e.pointerCount) {
                if (i == skip) continue
                val x = if (h < 0) e.getX(i) else e.getHistoricalX(i, h)
                val y = if (h < 0) e.getY(i) else e.getHistoricalY(i, h)
                sb.append(' ').append(e.getPointerId(i))
                    .append(' ').append(mm(x))
                    .append(' ').append(mm(y))
            }
        }
        sb.append('\n')
        onFrame(sb.toString(), count == 0)
    }

    private fun mm(px: Float): Float = (px * mmPerPx * 100f).roundToInt() / 100f

    private fun detectFiveFingerTap(e: MotionEvent) {
        if (e.pointerCount >= 5 && fiveStart < 0) fiveStart = e.eventTime
        if (e.actionMasked == MotionEvent.ACTION_UP) {
            if (fiveStart >= 0 && e.eventTime - e.downTime < 500) onFiveFingerTap()
            fiveStart = -1
        }
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        canvas.drawText(status, cx, 40f * dm.density, textPaint)
        canvas.drawText("Tap with five fingers for options", cx, height - 24f * dm.density, hintPaint)
        val ev = lastEvent ?: return
        val r = 22f * dm.density
        for (i in 0 until ev.pointerCount) canvas.drawCircle(ev.getX(i), ev.getY(i), r, dotPaint)
    }

    companion object {
        private const val ALL = -2
    }
}
