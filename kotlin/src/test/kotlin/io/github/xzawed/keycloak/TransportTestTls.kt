package io.github.xzawed.keycloak

import java.io.FileInputStream
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManagerFactory
import kotlin.test.assertTrue

// 운송 시험(TransportParityTest · ConnectionReuseTest)이 함께 쓰는 TLS 키 — 시험 JVM 에서 한 번 keytool 로 만든다(저장소에 키를 두지
// 않는다). 저장소 암호도 실행마다 새로 만든다(Sonar S6437). Java 의 두 시험이 각자 만들던 것과 같은 키다.
internal object TransportTestTls {
    private val storepass: String = UUID.randomUUID().toString()
    private val dir: Path = Files.createTempDirectory("kc-transport-tls").also { it.toFile().deleteOnExit() }

    private val ip: KeyStore by lazy { keystore("ip", "CN=127.0.0.1", "SAN=ip:127.0.0.1,dns:localhost") }
    private val other: KeyStore by lazy { keystore("other", "CN=other.example", "SAN=dns:other.example") }
    private val tunnelled: KeyStore by lazy { keystore("tunnelled", "CN=kc.invalid", "SAN=dns:kc.invalid") }

    /** SAN 이 127.0.0.1 인 서버 키. */
    val serverIp: SSLContext by lazy { serverContext(ip) }

    /** 다른 이름(other.example)의 서버 키. */
    val serverOther: SSLContext by lazy { serverContext(other) }

    /**
     * [serverOther] 의 키로, 핸드셰이크 뒤 세션 티켓을 보내지 않는 서버 — JDK 의 TLS 1.3 서버는 세션 시한이 7 일을 넘으면 티켓을
     * 보내지 않는다(`NewSessionTicket` 「Session timeout is too long」). 보내면 그 바이트가 와 있어 JSSE 의 닫기가 기다리지 않는다.
     */
    val serverOtherWithoutTickets: SSLContext by lazy {
        serverContext(other).also { it.serverSessionContext.sessionTimeout = 8 * 24 * 3600 }
    }

    /** 프록시 터널 너머의 이름(kc.invalid) — 터널 시험의 TLS 서버 키. */
    val serverTunnelled: SSLContext by lazy { serverContext(tunnelled) }

    /** 위 셋을 믿는 클라이언트 팩토리. */
    val trusting: SSLSocketFactory by lazy {
        val trust = KeyStore.getInstance("PKCS12")
        trust.load(null, null)
        trust.setCertificateEntry("ip", ip.getCertificate("ip"))
        trust.setCertificateEntry("other", other.getCertificate("other"))
        trust.setCertificateEntry("tunnelled", tunnelled.getCertificate("tunnelled"))
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(trust)
        SSLContext.getInstance("TLS").apply { init(null, tmf.trustManagers, null) }.socketFactory
    }

    private fun keystore(
        alias: String,
        dname: String,
        san: String,
    ): KeyStore {
        val file = dir.resolve("$alias.p12")
        val keytool = Path.of(System.getProperty("java.home"), "bin", "keytool").toString()
        val p =
            ProcessBuilder(
                keytool,
                "-genkeypair",
                "-alias",
                alias,
                "-keyalg",
                "EC",
                "-groupname",
                "secp256r1",
                "-validity",
                "2",
                "-dname",
                dname,
                "-ext",
                san,
                "-keystore",
                file.toString(),
                "-storetype",
                "PKCS12",
                "-storepass",
                storepass,
                "-keypass",
                storepass,
            ).redirectErrorStream(true).start()
        val out = String(p.inputStream.readAllBytes(), Charsets.UTF_8)
        assertTrue(p.waitFor(60, TimeUnit.SECONDS) && p.exitValue() == 0, "keytool 실패: $out")
        file.toFile().deleteOnExit()
        return KeyStore.getInstance("PKCS12").apply { FileInputStream(file.toFile()).use { load(it, storepass.toCharArray()) } }
    }

    private fun serverContext(ks: KeyStore): SSLContext {
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, storepass.toCharArray())
        return SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
    }
}
