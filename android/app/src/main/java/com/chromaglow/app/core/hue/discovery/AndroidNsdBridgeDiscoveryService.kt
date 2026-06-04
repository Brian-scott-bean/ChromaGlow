package com.chromaglow.app.core.hue.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executor

/**
 * LAN-only mDNS bridge discovery backed by the Android [NsdManager] platform adapter.
 *
 * Browses for the Hue DNS-SD service type and surfaces resolved endpoints as an explicit
 * chooser. It never auto-selects a bridge and never exchanges credentials. API 34+ uses the
 * continuous service-info callback path; API 26–33 uses a single-flight legacy resolve.
 */
class AndroidNsdBridgeDiscoveryService(
    context: Context,
) : BridgeDiscoveryService {

    private val appContext: Context = context.applicationContext
    private val nsdManager: NsdManager =
        appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager: WifiManager =
        appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { command -> mainHandler.post(command) }

    private var onSnapshot: ((BridgeDiscoverySnapshot) -> Unit)? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private var isScanning = false
    private var isDiscoveryActive = false
    private var generation = 0
    private var statusMessage: String? = null

    private val endpointByServiceName = linkedMapOf<String, BridgeEndpoint>()
    private val serviceInfoCallbacks = mutableMapOf<String, NsdManager.ServiceInfoCallback>()

    private val pendingResolveQueue = ArrayDeque<NsdServiceInfo>()
    private var isResolving = false

    private val discoveredServiceNames = mutableSetOf<String>()
    private val queuedLegacyServiceNames = mutableSetOf<String>()
    private var currentlyResolvingServiceName: String? = null

    override fun start(onSnapshot: (BridgeDiscoverySnapshot) -> Unit) {
        runOnMain {
            this.onSnapshot = onSnapshot
            if (isScanning) {
                publish()
                return@runOnMain
            }
            generation += 1
            val gen = generation
            clearServiceTracking()
            endpointByServiceName.clear()
            isScanning = true
            statusMessage = null
            publish()

            val listener = buildDiscoveryListener(gen)
            discoveryListener = listener
            try {
                acquireMulticastLock()
                nsdManager.discoverServices(
                    HUE_SERVICE_TYPE,
                    NsdManager.PROTOCOL_DNS_SD,
                    listener,
                )
            } catch (_: IllegalArgumentException) {
                discoveryListener = null
                isDiscoveryActive = false
                isScanning = false
                releaseMulticastLock()
                statusMessage = DISCOVERY_FAILED_MESSAGE
                publish()
            } catch (_: SecurityException) {
                discoveryListener = null
                isDiscoveryActive = false
                isScanning = false
                releaseMulticastLock()
                statusMessage = DISCOVERY_FAILED_MESSAGE
                publish()
            }
        }
    }

    override fun stop() {
        runOnMain {
            generation += 1
            stopActiveDiscovery()
            clearServiceTracking()
            releaseMulticastLock()
            isScanning = false
            publish()
        }
    }

    private fun buildDiscoveryListener(gen: Int): NsdManager.DiscoveryListener =
        object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    isDiscoveryActive = true
                    isScanning = true
                    publish()
                }
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    discoveryListener = null
                    isDiscoveryActive = false
                    releaseLocalResourcesSafely()
                    isScanning = false
                    statusMessage = DISCOVERY_FAILED_MESSAGE
                    publish()
                }
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    handleServiceFound(serviceInfo, gen)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    handleServiceLost(serviceInfo)
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    isDiscoveryActive = false
                    isScanning = false
                    releaseMulticastLock()
                    publish()
                }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    isDiscoveryActive = false
                    releaseLocalResourcesSafely()
                    isScanning = false
                    statusMessage = STOP_FAILED_MESSAGE
                    publish()
                }
            }
        }

    private fun handleServiceFound(serviceInfo: NsdServiceInfo, gen: Int) {
        val serviceName = serviceInfo.serviceName?.takeIf { it.isNotBlank() } ?: return
        discoveredServiceNames.add(serviceName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            registerServiceInfoCallback(serviceName, serviceInfo, gen)
        } else {
            enqueueLegacyResolve(serviceName, serviceInfo)
        }
    }

    private fun handleServiceLost(serviceInfo: NsdServiceInfo) {
        val serviceName = serviceInfo.serviceName?.takeIf { it.isNotBlank() } ?: return
        discoveredServiceNames.remove(serviceName)
        endpointByServiceName.remove(serviceName)
        unregisterServiceInfoCallback(serviceName)
        pendingResolveQueue.removeAll { it.serviceName == serviceName }
        queuedLegacyServiceNames.remove(serviceName)
        publish()
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun registerServiceInfoCallback(
        serviceName: String,
        serviceInfo: NsdServiceInfo,
        gen: Int,
    ) {
        if (serviceInfoCallbacks.containsKey(serviceName)) return

        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    removeServiceInfoCallbackIfCurrent(serviceName, this)
                }
            }

            override fun onServiceUpdated(updated: NsdServiceInfo) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    val endpoint = extractEndpointApi34(updated)
                    if (endpoint == null) {
                        endpointByServiceName.remove(serviceName)
                    } else {
                        endpointByServiceName[serviceName] = endpoint
                    }
                    publish()
                }
            }

            override fun onServiceLost() {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    endpointByServiceName.remove(serviceName)
                    publish()
                }
            }

            override fun onServiceInfoCallbackUnregistered() {
                runOnMain {
                    removeServiceInfoCallbackIfCurrent(serviceName, this)
                }
            }
        }

        serviceInfoCallbacks[serviceName] = callback
        try {
            nsdManager.registerServiceInfoCallback(serviceInfo, mainExecutor, callback)
        } catch (_: IllegalArgumentException) {
            serviceInfoCallbacks.remove(serviceName)
        }
    }

    private fun enqueueLegacyResolve(serviceName: String, serviceInfo: NsdServiceInfo) {
        if (serviceName in queuedLegacyServiceNames) return
        if (serviceName == currentlyResolvingServiceName) return
        queuedLegacyServiceNames.add(serviceName)
        pendingResolveQueue.addLast(serviceInfo)
        drainLegacyResolveQueue()
    }

    private fun drainLegacyResolveQueue() {
        if (isResolving) return
        val next = pendingResolveQueue.removeFirstOrNull() ?: return
        val serviceName = next.serviceName?.takeIf { it.isNotBlank() }
        if (serviceName != null) queuedLegacyServiceNames.remove(serviceName)
        currentlyResolvingServiceName = serviceName
        isResolving = true
        val gen = generation
        @Suppress("DEPRECATION")
        nsdManager.resolveService(next, buildLegacyResolveListener(gen))
    }

    @Suppress("DEPRECATION")
    private fun buildLegacyResolveListener(gen: Int): NsdManager.ResolveListener =
        object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    isResolving = false
                    currentlyResolvingServiceName = null
                    drainLegacyResolveQueue()
                }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                runOnMain {
                    if (gen != generation) return@runOnMain
                    isResolving = false
                    currentlyResolvingServiceName = null
                    val serviceName = serviceInfo.serviceName?.takeIf { it.isNotBlank() }
                    val endpoint = extractEndpointLegacy(serviceInfo)
                    if (serviceName != null &&
                        endpoint != null &&
                        serviceName in discoveredServiceNames
                    ) {
                        endpointByServiceName[serviceName] = endpoint
                        publish()
                    }
                    drainLegacyResolveQueue()
                }
            }
        }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun extractEndpointApi34(serviceInfo: NsdServiceInfo): BridgeEndpoint? {
        val addresses = serviceInfo.hostAddresses
        if (addresses.isEmpty()) return null
        val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.first()
        return buildEndpoint(serviceInfo.serviceName, address, serviceInfo.port)
    }

    @Suppress("DEPRECATION")
    private fun extractEndpointLegacy(serviceInfo: NsdServiceInfo): BridgeEndpoint? {
        val address = serviceInfo.host ?: return null
        return buildEndpoint(serviceInfo.serviceName, address, serviceInfo.port)
    }

    private fun buildEndpoint(
        serviceName: String?,
        address: InetAddress,
        port: Int,
    ): BridgeEndpoint? {
        val host = address.hostAddress?.takeIf { it.isNotBlank() } ?: return null
        if (port !in 1..65535) return null
        val name = serviceName?.takeIf { it.isNotBlank() } ?: host
        return try {
            BridgeEndpoint(name = name, host = host, port = port)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun stopActiveDiscovery() {
        val listener = discoveryListener
        if (listener != null) {
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (_: IllegalArgumentException) {
                // Listener may not be fully registered yet; rejection is expected.
            }
        }
        discoveryListener = null
        isDiscoveryActive = false
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun removeServiceInfoCallbackIfCurrent(
        serviceName: String,
        callback: NsdManager.ServiceInfoCallback,
    ) {
        if (serviceInfoCallbacks[serviceName] === callback) {
            serviceInfoCallbacks.remove(serviceName)
        }
    }

    private fun unregisterServiceInfoCallback(serviceName: String) {
        val callback = serviceInfoCallbacks.remove(serviceName) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                nsdManager.unregisterServiceInfoCallback(callback)
            } catch (_: IllegalArgumentException) {
                // Callback already unregistered.
            }
        }
    }

    private fun unregisterAllServiceInfoCallbacks() {
        if (serviceInfoCallbacks.isEmpty()) return
        val callbacks = serviceInfoCallbacks.values.toList()
        serviceInfoCallbacks.clear()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        for (callback in callbacks) {
            try {
                nsdManager.unregisterServiceInfoCallback(callback)
            } catch (_: IllegalArgumentException) {
                // Callback already unregistered.
            }
        }
    }

    private fun clearServiceTracking() {
        unregisterAllServiceInfoCallbacks()
        pendingResolveQueue.clear()
        isResolving = false
        discoveredServiceNames.clear()
        queuedLegacyServiceNames.clear()
        currentlyResolvingServiceName = null
    }

    private fun releaseLocalResourcesSafely() {
        clearServiceTracking()
        releaseMulticastLock()
    }

    private fun acquireMulticastLock() {
        val lock = multicastLock ?: wifiManager.createMulticastLock(MULTICAST_LOCK_TAG).also {
            it.setReferenceCounted(false)
            multicastLock = it
        }
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        if (lock.isHeld) lock.release()
    }

    private fun publish() {
        val snapshot = BridgeDiscoverySnapshot(
            isScanning = isScanning,
            choices = BridgeEndpointDeduper.deduplicate(endpointByServiceName.values.toList()),
            statusMessage = statusMessage,
        )
        onSnapshot?.invoke(snapshot)
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }

    private companion object {
        const val HUE_SERVICE_TYPE = "_hue._tcp"
        const val MULTICAST_LOCK_TAG = "chromaglow-mdns-discovery"
        const val DISCOVERY_FAILED_MESSAGE = "Bridge discovery is unavailable. Tap Scan Again."
        const val STOP_FAILED_MESSAGE = "Discovery stopped with an error."
    }
}
