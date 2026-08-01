package com.pipilot.pi_pilot

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log

/// Phase 3 NSD 发现:Bridge 换地址(DHCP/换路由器)后的自愈来源。
///
/// 边界(与 bridge announce 侧的威胁模型一致):
/// - TXT 里的 bridgeId/ipv4 只是发现提示,同网任何设备都能伪造——身份以
///   认证后 bridge_hello 为准,这里绝不把 TXT 当信任根;
/// - 优先采用 TXT 的 ipv4 而不是 mDNS 解析地址:实测 avahi 会把服务解析到
///   Docker/VPN 虚地址(172.x),TXT ipv4 才是物理网卡地址;
/// - 禁止后台 /24 网段扫描,NSD 是唯一的被动发现通道。
class NsdDiscovery(context: Context) {
    data class Candidate(
        val serviceName: String,
        val host: String,
        val port: Int,
        val bridgeId: String?,
        val hubId: String?,
        val notify: Boolean,
    )

    private val manager = context.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())

    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var finished = false

    /// 发现一轮,超时自动收尾。回调一定恰好触发一次(可能空列表)。
    /// 返回 false 表示设备不支持 NSD。
    fun discoverOnce(
        timeoutMs: Long = 4000L,
        serviceType: String = "_pipilot._tcp.",
        callback: (List<Candidate>) -> Unit,
    ): Boolean {
        if (manager == null) return false
        val found = mutableMapOf<String, Candidate>()
        val pending = mutableSetOf<String>()

        fun finish() {
            if (finished) return
            finished = true
            discoveryListener?.let { runCatching { manager.stopServiceDiscovery(it) } }
            discoveryListener = null
            handler.post { callback(found.values.toList()) }
        }

        val resolveListenerFor = { name: String ->
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    pending.remove(name)
                    Log.w(tag, "resolve failed($name, err=$errorCode)")
                    if (pending.isEmpty()) handler.postDelayed({ finish() }, 300)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    pending.remove(name)
                    // TXT 属性值是 ByteArray;老设备可能为空,降级为纯地址候选。
                    val txt = serviceInfo.attributes.mapValues { (_, v) ->
                        v?.toString(Charsets.UTF_8).orEmpty()
                    }
                    // TXT ipv4 优先于解析地址——虚网卡问题在验收机上实测出现过。
                    val advertised = txt["ipv4"]?.takeIf { it.isNotEmpty() }
                    val host = advertised
                        ?: serviceInfo.host?.hostAddress
                        ?: return
                    found[name] = Candidate(
                        serviceName = name,
                        host = host,
                        port = serviceInfo.port,
                        bridgeId = txt["bridgeId"]?.takeIf { it.isNotEmpty() },
                        hubId = txt["hubId"]?.takeIf { it.isNotEmpty() },
                        notify = txt["notify"] == "1",
                    )
                    if (pending.isEmpty()) handler.postDelayed({ finish() }, 300)
                }
            }
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(tag, "start discovery failed(err=$errorCode)")
                finish()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                found.remove(serviceInfo.serviceName)
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName ?: return
                if (pending.contains(name) || found.containsKey(name)) return
                pending.add(name)
                runCatching { manager.resolveService(serviceInfo, resolveListenerFor(name)) }
                    .onFailure {
                        pending.remove(name)
                        Log.w(tag, "resolve submit failed($name): ${it.message}")
                    }
            }
        }

        return runCatching {
            discoveryListener = listener
            manager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
            handler.postDelayed({ finish() }, timeoutMs)
            true
        }.getOrElse {
            Log.w(tag, "discoverServices failed: ${it.message}")
            discoveryListener = null
            false
        }
    }

    fun stop() {
        if (finished) return
        finished = true
        discoveryListener?.let { runCatching { manager?.stopServiceDiscovery(it) } }
        discoveryListener = null
    }

    private companion object {
        const val tag = "NsdDiscovery"
    }
}
