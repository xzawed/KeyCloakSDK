// measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
//
// What id does AdminClient.users().create return when the 201's Location carries a byte that is not visible ASCII? A raw
// ServerSocket answers the admin-client's token grant with a token and the create with 201 +
// `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd` (Latin-1
// obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE) and what
// the SDK returns (ID). The SDK goes through RESTEasy + Apache HttpClient 4, as the Java SDK does.
//
// Run: cd kotlin && N3_OUT=<file> ./gradlew test --tests "*zz_n3_location_measureTest"
@file:Suppress("ktlint")

package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakConfig
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.keycloak.representations.idm.UserRepresentation
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList

class zz_n3_location_measureTest {
    private val users = "/admin/realms/it-realm/users"
    private val seen = CopyOnWriteArrayList<String>()

    @Volatile
    private var location = ByteArray(0)

    private fun indexOf(hay: ByteArray, needle: ByteArray, from: Int = 0): Int {
        var i = from
        while (i + needle.size <= hay.size) {
            if (needle.indices.all { hay[i + it] == needle[it] }) return i
            i++
        }
        return -1
    }

    private fun hex(b: ByteArray): String = b.joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }

    private fun show(s: String?): String {
        if (s == null) return "null"
        val esc = StringBuilder("\"")
        val cps = mutableListOf<String>()
        s.codePoints().forEach { cp ->
            esc.append(if (cp in 0x20..0x7E) Character.toString(cp) else "\\u%04X".format(cp))
            cps.add("U+%04X".format(cp))
        }
        return esc.append("\" cps=[").append(cps.joinToString(",")).append(']').toString()
    }

    private fun handle(conn: Socket) {
        conn.use {
            try {
                val input = conn.getInputStream()
                val buf = ByteArrayOutputStream()
                val chunk = ByteArray(4096)
                var headEnd: Int
                while (true) {
                    headEnd = indexOf(buf.toByteArray(), "\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    if (headEnd >= 0) break
                    val n = input.read(chunk)
                    if (n < 0) return
                    buf.write(chunk, 0, n)
                }
                val all = buf.toByteArray()
                val lines = String(all, 0, headEnd, Charsets.ISO_8859_1).split("\r\n")
                val first = lines[0].split(" ")
                val method = first[0]
                val path = first.getOrElse(1) { "" }
                var length = 0
                var chunked = false
                for (line in lines.drop(1)) {
                    val colon = line.indexOf(':')
                    if (colon < 0) continue
                    val name = line.substring(0, colon).trim().lowercase()
                    val value = line.substring(colon + 1).trim()
                    if (name == "content-length") length = value.toInt()
                    if (name == "transfer-encoding" && value.lowercase().contains("chunked")) chunked = true
                }
                var have = all.size - (headEnd + 4)
                if (chunked) {
                    while (indexOf(buf.toByteArray(), "0\r\n\r\n".toByteArray(Charsets.US_ASCII), headEnd + 4) < 0) {
                        val n = input.read(chunk)
                        if (n < 0) break
                        buf.write(chunk, 0, n)
                    }
                } else {
                    while (have < length) {
                        val n = input.read(chunk)
                        if (n < 0) break
                        have += n
                    }
                }
                seen.add("$method $path")
                val answer =
                    when {
                        path.endsWith("/protocol/openid-connect/token") -> {
                            val json = """{"access_token":"at-n3","token_type":"Bearer","expires_in":300}"""
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${json.length}\r\nConnection: close\r\n\r\n$json"
                                .toByteArray(Charsets.US_ASCII)
                        }
                        method == "POST" && path.trimEnd('/') == users ->
                            "HTTP/1.1 201 Created\r\nLocation: ".toByteArray(Charsets.US_ASCII) + location +
                                "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII)
                        else -> "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII)
                    }
                conn.getOutputStream().apply {
                    write(answer)
                    flush()
                }
            } catch (e: IOException) {
                // the client went away
            }
        }
    }

    private fun wireProbe(port: Int): ByteArray {
        Socket(InetAddress.getLoopbackAddress(), port).use { s ->
            s.getOutputStream().write(
                "POST $users HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII),
            )
            val raw = s.getInputStream().readAllBytes()
            val marker = "\r\nLocation: ".toByteArray(Charsets.US_ASCII)
            val at = indexOf(raw, marker)
            if (at < 0) return ByteArray(0)
            val start = at + marker.size
            return raw.copyOfRange(start, indexOf(raw, "\r\n".toByteArray(Charsets.US_ASCII), start))
        }
    }

    @Test
    fun measure() {
        val outPath = System.getenv("N3_OUT")
        assumeTrue(!outPath.isNullOrEmpty(), "measurement only — set N3_OUT")
        ServerSocket(0, 50, InetAddress.getLoopbackAddress()).use { server ->
            Thread {
                while (!server.isClosed) {
                    val conn =
                        try {
                            server.accept()
                        } catch (e: IOException) {
                            return@Thread
                        }
                    Thread { handle(conn) }.start()
                }
            }.apply { isDaemon = true }.start()
            val port = server.localPort
            val base = "http://127.0.0.1:$port"
            val out = mutableListOf(
                "ENV|java=${System.getProperty("java.version")}|kotlin=${KotlinVersion.CURRENT}|keycloak-admin-client=" +
                    "${org.keycloak.admin.client.Keycloak::class.java.`package`.implementationVersion}|httpclient=" +
                    "${org.apache.http.client.HttpClient::class.java.`package`.implementationVersion}|create=AdminClient.users().create",
                "HEADER|sdk|lane|case|field|value",
            )
            val cases =
                listOf(
                    "ascii-control" to "abc".toByteArray(Charsets.US_ASCII),
                    "latin1-0xE9" to byteArrayOf(0x61, 0x62, 0xE9.toByte(), 0x63, 0x64),
                    "utf8-0xC3A9" to byteArrayOf(0x61, 0x62, 0xC3.toByte(), 0xA9.toByte(), 0x63, 0x64),
                )
            val config =
                KeycloakConfig(
                    serverUrl = base,
                    realm = "it-realm",
                    clientId = "it-client",
                    clientSecret = "dummy-secret".toCharArray(),
                    connectTimeout = Duration.ofSeconds(5),
                    readTimeout = Duration.ofSeconds(5),
                )
            for ((name, id) in cases) {
                val prefix = "$base$users/".toByteArray(Charsets.US_ASCII)
                location = prefix + id
                val got = wireProbe(port)
                out.add(
                    "WIRE|kotlin|-|$name|location=<base>/admin/realms/it-realm/users/+[${hex(id)}]|raw_socket_read_equals_sent=" +
                        "${got.contentEquals(location)}|id_bytes_on_wire=${hex(got.copyOfRange(minOf(prefix.size, got.size), got.size))}",
                )
                seen.clear()
                val result =
                    try {
                        AdminClient(config).use { admin ->
                            "Ok(${show(runBlocking { admin.users().create(UserRepresentation().apply { username = "n3-user" }) })})"
                        }
                    } catch (e: Exception) {
                        val c = e.cause
                        "Err(${e.javaClass.name}: ${e.message}${if (c == null) "" else " cause=${c.javaClass.name}: ${c.message}"})"
                    }
                out.add("ID|kotlin|AdminClient.users().create|$name|${result.replace('|', '/').replace('\n', ' ')}|requests=${seen.joinToString(",")}")
            }
            Files.writeString(Path.of(outPath), out.joinToString("\n") + "\n")
            assertEquals(3, out.count { it.startsWith("ID|") })
        }
    }
}
