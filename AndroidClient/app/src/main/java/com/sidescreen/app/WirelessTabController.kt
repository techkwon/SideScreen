package com.sidescreen.app

import android.view.View
import android.widget.Button
import android.widget.TextView

/**
 * Wireless tab state machine for the native Android client.
 *
 * Pairing runs through the phone's Camera app: the Mac shows a `sidescreen://` QR,
 * scanning it opens this app via the deep link, and the token in the URL authorises
 * the stream. There is no in-app scanner, so the Scan button only explains that.
 */
class WirelessTabController(
    private val views: Views,
    private val storage: PairedHostStorage,
    private val onConnectRequested: (
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        macName: String,
    ) -> Unit,
) {
    data class Views(
        val connecting: View,
        val firstTime: View,
        val connected: View,
        val pairedIdle: View,
        val repair: View,
        val scanButton: Button,
        val rescanButton: Button,
        val disconnectButton: Button,
        val forgetButton: Button,
        val reconnectButton: Button,
        val idleForgetButton: Button,
        val connectedMacName: TextView,
        val connectedMacIp: TextView,
        val connectingLabel: TextView,
        val connectingSubtitle: TextView,
        val idleMacName: TextView,
        val idleMacIp: TextView,
        val repairTitle: TextView,
        val repairMessage: TextView,
    )

    enum class State { FIRST_TIME, CONNECTING, CONNECTED, PAIRED_IDLE, REPAIR_NEEDED }

    private var state: State = State.FIRST_TIME

    fun bind() {
        views.scanButton.setOnClickListener { showPairingInstruction() }
        views.rescanButton.setOnClickListener { showPairingInstruction() }
        views.forgetButton.setOnClickListener {
            storage.clear()
            transition(State.FIRST_TIME)
        }
        views.idleForgetButton.setOnClickListener {
            storage.clear()
            transition(State.FIRST_TIME)
        }
        views.reconnectButton.setOnClickListener {
            val entry =
                storage.load() ?: run {
                    transition(State.FIRST_TIME)
                    return@setOnClickListener
                }
            showConnecting("Reconnecting to ${entry.macName}", "${entry.host}:${entry.port}")
            attemptAutoConnect(entry)
        }
    }

    /**
     * Called when the TCP stream goes down (user tapped Disconnect, network drop, etc).
     * Move the UI to a clean "paired but idle" state showing the Mac info + Reconnect button.
     */
    fun onStreamDisconnected() {
        android.util.Log.i(
            "WirelessTabController",
            "onStreamDisconnected called, current state=$state, storage entry exists=${storage.load() != null}",
        )
        val entry =
            storage.load() ?: run {
                transition(State.FIRST_TIME)
                return
            }
        views.idleMacName.text = entry.macName
        views.idleMacIp.text = "${entry.host}:${entry.port}"
        transition(State.PAIRED_IDLE)
    }

    private fun transition(next: State) {
        android.util.Log.i("WirelessTabController", "transition $state → $next")
        state = next
        views.connecting.visibility = if (next == State.CONNECTING) View.VISIBLE else View.GONE
        views.firstTime.visibility = if (next == State.FIRST_TIME) View.VISIBLE else View.GONE
        views.connected.visibility = if (next == State.CONNECTED) View.VISIBLE else View.GONE
        views.pairedIdle.visibility = if (next == State.PAIRED_IDLE) View.VISIBLE else View.GONE
        views.repair.visibility = if (next == State.REPAIR_NEEDED) View.VISIBLE else View.GONE
    }

    /**
     * Called when the Wireless tab becomes visible. Decides initial state based on
     * cached host state.
     *
     * No auto-connect: even when a cached pairing exists, the user must press
     * the Reconnect button to actually start a connection. Auto-connect was
     * confusing because it could run silently while the user toggled tabs.
     */
    fun show() {
        when {
            storage.load() == null -> transition(State.FIRST_TIME)
            else -> {
                val entry = storage.load()!!
                views.idleMacName.text = entry.macName
                views.idleMacIp.text = "${entry.host}:${entry.port}"
                transition(State.PAIRED_IDLE)
            }
        }
    }

    fun onScanResult(url: String) {
        val parsed = PairingURL.parse(url) ?: return
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        storage.save(PairedHostStorage.Entry(parsed.host, parsed.port, parsed.token, parsed.macName))
        showConnecting("Connecting to ${parsed.macName}", "${parsed.host}:${parsed.port}")
        onConnectRequested(parsed.host, parsed.port, parsed.token, deviceName, parsed.macName)
    }

    fun onConnectError(error: StreamClient.WirelessConnectError) {
        val cached = storage.load()
        when (error) {
            is StreamClient.WirelessConnectError.NetworkUnreachable -> {
                views.repairTitle.text = "⚠ Couldn't reach Mac"
                views.repairMessage.text =
                    if (cached != null) {
                        "No response from ${cached.macName} at ${cached.host}:${cached.port}.\n\n" +
                            "The Mac may have switched WiFi networks, changed its port, or is not " +
                            "running. Open SideScreen on the Mac and scan the new QR to re-pair."
                    } else {
                        "No response from your Mac. Make sure both devices are on the same WiFi " +
                            "and the Mac app is running, then scan the QR again."
                    }
                transition(State.REPAIR_NEEDED)
            }
            is StreamClient.WirelessConnectError.TokenRejected -> {
                views.repairTitle.text = "⚠ Re-pair required"
                views.repairMessage.text =
                    if (cached != null) {
                        "${cached.macName} reset its pairing token (e.g. Reset Token clicked, or " +
                            "reinstalled). Scan the new QR to pair again."
                    } else {
                        "The Mac reset its pairing token. Scan the new QR to pair again."
                    }
                transition(State.REPAIR_NEEDED)
            }
            is StreamClient.WirelessConnectError.ProtocolError -> {
                views.repairTitle.text = "⚠ Connection error"
                views.repairMessage.text = "Couldn't complete the secure handshake with the Mac. Scan the QR again."
                transition(State.REPAIR_NEEDED)
            }
        }
    }

    private fun showConnecting(
        title: String,
        subtitle: String,
    ) {
        views.connectingLabel.text = title
        views.connectingSubtitle.text = subtitle
        transition(State.CONNECTING)
    }

    fun onConnectSuccess(
        macName: String,
        ip: String,
    ) {
        views.connectedMacName.text = macName
        views.connectedMacIp.text = ip
        transition(State.CONNECTED)
    }

    private fun showPairingInstruction() {
        views.repairTitle.text = "Scan with the Camera app"
        // There is no in-app scanner — this app pairs by being opened through the
        // sidescreen:// deep link the QR carries, so the phone's own Camera app is
        // what does the scanning.
        views.repairMessage.text =
            "Open the phone Camera app and point it at the QR on the Mac. " +
            "It opens Side Screen and connects over WiFi."
        transition(State.REPAIR_NEEDED)
    }

    private fun attemptAutoConnect(entry: PairedHostStorage.Entry) {
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        onConnectRequested(entry.host, entry.port, entry.token, deviceName, entry.macName)
    }
}
