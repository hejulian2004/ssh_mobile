package com.hejulian.android_server_widgets

/** Bounded, whitelisted channel input. No arbitrary config fields survive. */
data class WidgetWrite(
    val session: String,
    val sequence: Long,
    val servers: List<WidgetServer>,
    val snapshots: List<MonitorSnapshot>,
    val invalidatedBefore: Map<String, Long>,
    val reset: Boolean,
) {
    companion object {
        fun fromMap(map: Map<*, *>, now: Long = System.currentTimeMillis()): WidgetWrite {
            val session = map["session"] as? String ?: throw IllegalArgumentException()
            require(session.length in 1..64)
            val sequence = requireNotNull(integer(map["sequence"]))
            require(sequence > 0)
            val rawServers = map["servers"] as? List<*> ?: throw IllegalArgumentException()
            val rawSnapshots = map["snapshots"] as? List<*> ?: throw IllegalArgumentException()
            val rawCutoffs = map["invalidatedBefore"] as? Map<*, *> ?: throw IllegalArgumentException()
            require(rawServers.size <= 100 && rawSnapshots.size <= 100 && rawCutoffs.size <= 100)
            val servers = rawServers.map {
                val entry = it as? Map<*, *> ?: throw IllegalArgumentException()
                val id = entry["connectionId"] as? String ?: throw IllegalArgumentException()
                require(validConnectionId(id))
                WidgetServer(id, safeDisplayName(entry["displayName"] as? String ?: ""))
            }
            val snapshots = rawSnapshots.map {
                requireNotNull(MonitorSnapshot.fromMap(it as? Map<*, *> ?: emptyMap<Any, Any>(), now))
            }
            val cutoffs = rawCutoffs.entries.associate { (id, time) ->
                require(id is String && validConnectionId(id))
                val cutoff = requireNotNull(integer(time))
                require(cutoff >= 0)
                id to cutoff
            }
            require(servers.map { it.connectionId }.toSet().size == servers.size)
            require(snapshots.map { it.connectionId }.toSet().size == snapshots.size)
            return WidgetWrite(session, sequence, servers, snapshots, cutoffs, map["reset"] == true)
        }
    }
}
