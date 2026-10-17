package com.example.platform;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.FileTime;
import java.math.BigInteger;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration;
import org.springframework.boot.data.redis.autoconfigure.DataRedisAutoConfiguration;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import static org.junit.jupiter.api.Assertions.*;

class TlsReloadTest {
    @TempDir Path directory;

    @SpringBootConfiguration
    @EnableAutoConfiguration(exclude = {DataSourceAutoConfiguration.class, DataRedisAutoConfiguration.class})
    static class Probe {}

    private void certificate(Path version, int serial) throws Exception {
        Files.createDirectories(version);
        var process = new ProcessBuilder("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", version.resolve("tls.key").toString(), "-out", version.resolve("tls.crt").toString(),
            "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-set_serial", Integer.toString(serial)).redirectErrorStream(true).start();
        var output = new String(process.getInputStream().readAllBytes());
        assertEquals(0, process.waitFor(), output);
    }

    private BigInteger servedSerial(int port, KeyStore trusted) throws Exception {
        // A fresh SSL context prevents TLS session resumption hiding a certificate change.
        var manager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        manager.init(trusted);
        var context = SSLContext.getInstance("TLS");
        context.init(null, manager.getTrustManagers(), null);
        try (var socket = (SSLSocket) context.getSocketFactory().createSocket("localhost", port)) {
            socket.setSoTimeout(3000);
            var parameters = socket.getSSLParameters();
            parameters.setEndpointIdentificationAlgorithm("HTTPS");
            socket.setSSLParameters(parameters);
            socket.startHandshake();
            return ((X509Certificate) socket.getSession().getPeerCertificates()[0]).getSerialNumber();
        }
    }

    @Test void reloadsProjectedSecretWithoutRestartingTomcat() throws Exception {
        certificate(directory.resolve("version1"), 1);
        certificate(directory.resolve("version2"), 2);
        for (var file : new String[]{"tls.crt", "tls.key"}) {
            Files.setLastModifiedTime(directory.resolve("version1").resolve(file), FileTime.fromMillis(1000));
            Files.createSymbolicLink(directory.resolve(file), Path.of("..data", file));
        }
        Files.createSymbolicLink(directory.resolve("..data"), Path.of("version1"));
        var trusted = KeyStore.getInstance(KeyStore.getDefaultType());
        trusted.load(null, null);
        for (int serial : new int[]{1, 2}) {
            try (var stream = Files.newInputStream(directory.resolve("version" + serial).resolve("tls.crt"))) {
                trusted.setCertificateEntry("cert" + serial, CertificateFactory.getInstance("X.509").generateCertificate(stream));
            }
        }
        // Read the real application configuration; only external clients are excluded.
        try (var app = new SpringApplicationBuilder(Probe.class).properties(
            "spring.main.banner-mode=off", "management.tracing.export.enabled=false",
            "TLS_CERT=" + directory.resolve("tls.crt").toUri(),
            "TLS_KEY=" + directory.resolve("tls.key").toUri(),
            "TLS_CA=" + directory.resolve("version1/tls.crt").toUri(),
            "spring.ssl.bundle.watch.file.quiet-period=100ms").run("--server.port=0")) {
            int port = ((ServletWebServerApplicationContext) app).getWebServer().getPort();
            assertEquals(BigInteger.ONE, servedSerial(port, trusted));
            Files.createSymbolicLink(directory.resolve("..data.next"), Path.of("version2"));
            Files.move(directory.resolve("..data.next"), directory.resolve("..data"),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            var deadline = System.nanoTime() + Duration.ofSeconds(20).toNanos();
            BigInteger serial;
            do {
                serial = servedSerial(port, trusted);
                if (serial.equals(BigInteger.TWO)) break;
                Thread.sleep(150);
            } while (System.nanoTime() < deadline);
            assertEquals(BigInteger.TWO, serial, "Projected Secret renewal must replace the served certificate");
            assertEquals(port, ((ServletWebServerApplicationContext) app).getWebServer().getPort());
        }
    }
}
