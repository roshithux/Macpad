package com.phonetrackpad.app

import android.app.Activity
import android.app.ActivityManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.VibrationEffect
import android.os.VibratorManager
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView

class MainActivity : Activity(), Link.Listener {

    private lateinit var pad: TouchpadView
    private lateinit var options: LinearLayout
    private lateinit var chooser: LinearLayout
    private lateinit var macList: LinearLayout
    private lateinit var naturalSwitch: Switch
    private lateinit var pinButton: Button
    private lateinit var link: Link
    private val vibrator by lazy { getSystemService(VibratorManager::class.java).defaultVibrator }
    // Stops Wi-Fi power saving while the trackpad is open (the main source of lag spikes).
    private val wifiLock by lazy {
        getSystemService(WifiManager::class.java)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "trackpad")
            .apply { setReferenceCounted(false) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        link = Link(this, this)
        pad = TouchpadView(this, onFrame = link::sendFrame, onFiveFingerTap = ::showOptions)
        options = buildOptions()
        chooser = buildChooser()

        val root = FrameLayout(this)
        root.addView(pad, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        root.addView(options, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        root.addView(chooser, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        setContentView(root)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        window.setDecorFitsSystemWindows(false)
        goImmersive()
    }

    override fun onStart() {
        super.onStart()
        wifiLock.acquire()
        link.start()
    }

    override fun onStop() {
        link.stop()
        wifiLock.release()
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goImmersive()
    }

    @Deprecated("Back closes the options panel first")
    override fun onBackPressed() {
        when {
            chooser.visibility == View.VISIBLE -> hideChooser()
            options.visibility == View.VISIBLE -> hideOptions()
            else -> @Suppress("DEPRECATION") super.onBackPressed()
        }
    }

    private fun goImmersive() {
        window.insetsController?.apply {
            hide(WindowInsets.Type.systemBars())
            systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    // Options panel (five-finger tap).

    private fun panel(title: String): LinearLayout {
        val d = resources.displayMetrics.density
        val pad = (20 * d).toInt()
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
            background = GradientDrawable().apply {
                setColor(Color.rgb(28, 28, 34))
                cornerRadius = 16 * d
            }
            visibility = View.GONE
            minimumWidth = (320 * d).toInt()
        }
        panel.addView(TextView(this).apply {
            text = title
            textSize = 18f
            setTextColor(Color.WHITE)
            setPadding(0, 0, 0, (12 * d).toInt())
        })
        return panel
    }

    private fun buildOptions(): LinearLayout {
        val d = resources.displayMetrics.density
        val panel = panel("Trackpad options")
        // Follows the Mac's setting; change it there in System Settings → Mouse.
        naturalSwitch = Switch(this).apply {
            text = "Natural scrolling (set on Mac)"
            textSize = 16f
            setTextColor(Color.rgb(220, 220, 228))
            isChecked = true
            isEnabled = false
        }
        panel.addView(naturalSwitch, LinearLayout.LayoutParams(MATCH_PARENT, (48 * d).toInt()))
        pinButton = Button(this).apply { setOnClickListener { togglePin() } }
        panel.addView(pinButton, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(Button(this).apply {
            text = "Choose another Mac"
            setOnClickListener { options.visibility = View.GONE; showChooser() }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(Button(this).apply {
            text = "Back to trackpad"
            setOnClickListener { hideOptions() }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(Button(this).apply {
            text = "Close app"
            setOnClickListener {
                if (isPinned()) stopLockTask()
                finishAndRemoveTask()
            }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        return panel
    }

    private fun showOptions() {
        pinButton.text = if (isPinned()) "Unpin screen" else "Pin screen (blocks Home & Recents)"
        options.visibility = View.VISIBLE
    }

    private fun hideOptions() {
        options.visibility = View.GONE
        goImmersive()
    }

    // Mac chooser: opens by itself when several Macs are found and none is chosen yet.

    private fun buildChooser(): LinearLayout {
        val panel = panel("Choose your Mac")
        macList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        panel.addView(macList, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(Button(this).apply {
            text = "Back to trackpad"
            setOnClickListener { hideChooser() }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        return panel
    }

    private fun showChooser() {
        chooser.visibility = View.VISIBLE
    }

    private fun hideChooser() {
        chooser.visibility = View.GONE
        goImmersive()
    }

    private fun fillChooser(names: List<String>, chosen: String?) {
        macList.removeAllViews()
        if (names.isEmpty()) {
            macList.addView(TextView(this).apply {
                text = "No Macs found yet. Open Phone Trackpad on your Mac and use the same Wi-Fi."
                setTextColor(Color.rgb(200, 200, 210))
            })
        }
        for (name in names) {
            macList.addView(Button(this).apply {
                text = if (name == chosen) "✓ $name" else name
                setOnClickListener {
                    link.choose(name)
                    hideChooser()
                }
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
    }

    private fun isPinned() =
        getSystemService(ActivityManager::class.java).lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE

    private fun togglePin() {
        if (isPinned()) stopLockTask() else startLockTask()
        hideOptions()
    }

    // Link.Listener (called from background threads).

    override fun onStatus(text: String, connected: Boolean) {
        runOnUiThread { pad.status = text }
    }

    override fun onHaptic() {
        vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
    }

    override fun onMacs(names: List<String>, chosen: String?, needsChoice: Boolean) {
        runOnUiThread {
            fillChooser(names, chosen)
            if (needsChoice && options.visibility != View.VISIBLE) showChooser()
        }
    }

    override fun onNatural(on: Boolean) {
        runOnUiThread {
            naturalSwitch.isChecked = on
        }
    }
}
