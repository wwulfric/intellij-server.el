// IntellijServerProxy: an LSP proxy in front of JetBrains' IntelliJ language server.
//
// Any LSP client can start this instead of the server.  It starts the server
// and fixes, at the protocol level, what the server expects from its VS Code
// client:
//
// - the launch: the EULA hash, persistent index and log directories, the heap;
// - settings: the server pulls flat dotted keys ("jetbrains.java.hints...")
//   with workspace/configuration, which this answers itself, from built-in
//   defaults overridden by the client's settings (initializationOptions
//   "settings" and workspace/didChangeConfiguration);
// - the project SDK: a Maven or Gradle root is pinned to $JAVA_HOME unless
//   the client lists its projects;
// - library sources: jar: and jrt: URIs only the server can read.  They are
//   decompiled into files under the data directory and shown to the client as
//   file: URIs, which are translated back on the way to the server.
//
// What needs the editor's own UI (the server's intellij/* questions, the
// completion items its apply command inserts) passes through unchanged.
//
// It runs on the Java runtime bundled with the server and needs nothing else:
//
//   java IntellijServerProxy.java --server DIR --data DIR [--java-home DIR]
//        [--jvm-arg ARG]... [--log FILE]

import java.io.*;
import java.math.BigDecimal;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

public final class IntellijServerProxy {
    private static final String[][] DEFAULT_SETTINGS = {
        {"jetbrains.kotlin.hints.parameters", "true"},
        {"jetbrains.kotlin.hints.parameters.compiled", "true"},
        {"jetbrains.kotlin.hints.parameters.excluded", "false"},
        {"jetbrains.kotlin.hints.parameters.context", "false"},
        {"jetbrains.kotlin.hints.type.property", "true"},
        {"jetbrains.kotlin.hints.type.variable", "true"},
        {"jetbrains.kotlin.hints.type.function.return", "true"},
        {"jetbrains.kotlin.hints.type.function.parameter", "true"},
        {"jetbrains.kotlin.hints.lambda.return", "true"},
        {"jetbrains.kotlin.hints.lambda.receivers.parameters", "true"},
        {"jetbrains.kotlin.hints.value.ranges", "true"},
        {"jetbrains.kotlin.hints.value.kotlin.time", "true"},
        {"jetbrains.kotlin.hints.call.chains", "false"},
        // The spaces and the odd "settings." are the server's own spelling.
        {"jetbrains.java.hints.settings.method parameter", "true"},
        {"jetbrains.java.hints.types.local variable", "true"},
        {"jetbrains.java.hints.collapse complex types", "true"},
        {"jetbrains.java.hints.types.call chain", "true"},
    };

    private final Path serverDir;
    private final Path dataDir;
    private final String javaHome;
    private final List<String> jvmArgs;
    private final PrintStream log;

    private Process server;
    private OutputStream toServer;
    private final OutputStream toClient = new BufferedOutputStream(new FileOutputStream(FileDescriptor.out));
    // Server messages reach the client in order, each after its sources are read.
    private final ExecutorService clientWriter = Executors.newSingleThreadExecutor();
    private final AtomicLong proxyIds = new AtomicLong();
    private final Map<String, CompletableFuture<Object>> pending = new ConcurrentHashMap<>();

    private final Map<String, Object> settings = new ConcurrentHashMap<>();
    private volatile Path sourcesDir;
    private final Map<String, String> archiveUriByPath = new ConcurrentHashMap<>();
    private final Map<String, String> fileUriByArchiveUri = new ConcurrentHashMap<>();

    private IntellijServerProxy(Path serverDir, Path dataDir, String javaHome, List<String> jvmArgs, PrintStream log) {
        this.serverDir = serverDir;
        this.dataDir = dataDir;
        this.javaHome = javaHome;
        this.jvmArgs = jvmArgs;
        this.log = log;
        for (String[] setting : DEFAULT_SETTINGS) {
            settings.put(setting[0], Boolean.valueOf(setting[1]));
        }
    }

    public static void main(String[] args) throws Exception {
        Path serverDir = null, dataDir = null;
        String javaHome = null;
        List<String> jvmArgs = new ArrayList<>();
        PrintStream log = null;
        for (int i = 0; i < args.length; i++) {
            String value = i + 1 < args.length ? args[i + 1] : null;
            switch (args[i]) {
                case "--server" -> { serverDir = Path.of(value); i++; }
                case "--data" -> { dataDir = Path.of(value); i++; }
                case "--java-home" -> { javaHome = value; i++; }
                case "--jvm-arg" -> { jvmArgs.add(value); i++; }
                case "--log" -> { log = new PrintStream(new FileOutputStream(value, true), true, StandardCharsets.UTF_8); i++; }
                default -> usage("unknown argument " + args[i]);
            }
        }
        if (serverDir == null) usage("--server is required");
        if (dataDir == null) dataDir = serverDir.resolveSibling("data");
        new IntellijServerProxy(serverDir.toAbsolutePath(), dataDir.toAbsolutePath(), javaHome, jvmArgs, log).run();
    }

    private static void usage(String problem) {
        System.err.println("intellij-server-proxy: " + problem);
        System.err.println("usage: IntellijServerProxy --server DIR [--data DIR] [--java-home DIR] [--jvm-arg ARG]... [--log FILE]");
        System.exit(2);
    }

    // Launch ---------------------------------------------------------------

    private void run() throws Exception {
        for (String sub : List.of("config", "system", "log", "sources")) {
            Files.createDirectories(dataDir.resolve(sub));
        }
        boolean windows = System.getProperty("os.name").startsWith("Windows");
        List<String> command = new ArrayList<>(List.of(
            serverDir.resolve(windows ? "bin/intellij-server.exe" : "bin/intellij-server").toString(), "--stdio"));
        String eula = eulaHash();
        if (eula != null) command.addAll(List.of("--eula", eula));

        ProcessBuilder builder = new ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.INHERIT);
        Map<String, String> env = builder.environment();
        env.put("JAVA_HOME", serverJavaHome(env.get("JAVA_HOME")));
        List<String> options = new ArrayList<>(List.of(
            "-Didea.config.path=" + dataDir.resolve("config"),
            "-Didea.system.path=" + dataDir.resolve("system"),
            "-Didea.log.path=" + dataDir.resolve("log"),
            // Name each heap dump instead of leaving one in $HOME that blocks the next.
            "-XX:HeapDumpPath=" + dataDir.resolve("log")));
        // Appended after the server's vmoptions, so the last -Xmx wins.
        options.addAll(jvmArgs);
        env.put("IJ_JAVA_OPTIONS", String.join(" ", options));
        // Validation plugins only slow down the Maven import.
        env.putIfAbsent("MAVEN_ARGS", "-Dcheckstyle.skip=true -Dpmd.skip=true -Dspotbugs.skip=true -Djacoco.skip=true");

        server = builder.start();
        toServer = new BufferedOutputStream(server.getOutputStream());
        Runtime.getRuntime().addShutdownHook(new Thread(this::stopServer));

        Thread fromServer = new Thread(() -> pump(server.getInputStream(), this::fromServer), "server");
        fromServer.start();
        pump(System.in, this::fromClient);
        // The client went away: give the server a moment to act on its exit.
        if (!server.waitFor(5, TimeUnit.SECONDS)) stopServer();
        fromServer.join(5000);
        clientWriter.shutdown();
        clientWriter.awaitTermination(5, TimeUnit.SECONDS);
        System.exit(server.isAlive() ? 0 : server.exitValue());
    }

    private String eulaHash() throws Exception {
        Path eula = serverDir.resolve("EULA.txt");
        if (!Files.isReadable(eula)) return null;
        return hex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(eula))).substring(0, 16);
    }

    private String serverJavaHome(String inherited) {
        if (javaHome != null) return javaHome;
        if (inherited != null && !inherited.isEmpty()) return inherited;
        Path mac = serverDir.resolve("jbr/Contents/Home");
        return (Files.isDirectory(mac) ? mac : serverDir.resolve("jbr")).toString();
    }

    private void stopServer() {
        if (server == null) return;
        // The server spawns a JVM and build tools of its own.
        server.descendants().forEach(ProcessHandle::destroy);
        server.destroy();
    }

    // Messages from the client ----------------------------------------------

    @SuppressWarnings("unchecked")
    private void fromClient(Map<String, Object> message) throws IOException {
        Object method = message.get("method");
        Object params = message.get("params");
        if ("initialize".equals(method) && params instanceof Map<?, ?> init) {
            initialize((Map<String, Object>) init);
        } else if ("workspace/didChangeConfiguration".equals(method) && params instanceof Map<?, ?> change) {
            flatten("", change.get("settings"), settings);
        }
        if (params != null) message.put("params", toServerUris(params));
        send(toServer, message);
    }

    @SuppressWarnings("unchecked")
    private void initialize(Map<String, Object> params) throws IOException {
        try {
            initialize1(params);
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
    }

    @SuppressWarnings("unchecked")
    private void initialize1(Map<String, Object> params) throws IOException, java.security.NoSuchAlgorithmException {
        Path root = null;
        if (params.get("rootUri") instanceof String uri) root = pathOf(uri);
        else if (params.get("rootPath") instanceof String path) root = Path.of(path);

        Map<String, Object> options = params.get("initializationOptions") instanceof Map<?, ?> given
            ? (Map<String, Object>) given : new LinkedHashMap<>();
        // The client's own settings travel here, not to the server.
        flatten("", options.remove("settings"), settings);
        if (root != null && !options.containsKey("projects")) {
            Map<String, Object> pinned = pinnedProject(root);
            if (pinned != null) options.put("projects", new ArrayList<>(List.of(pinned)));
        }
        params.put("initializationOptions", options);

        if (root != null) {
            sourcesDir = dataDir.resolve("sources").resolve(hex(MessageDigest.getInstance("SHA-1")
                .digest(root.toString().getBytes(StandardCharsets.UTF_8))).substring(0, 16)).toAbsolutePath();
            Files.createDirectories(sourcesDir);
            sourcesDir = sourcesDir.toRealPath();
            // Editors find the project a library source belongs to from here.
            Files.writeString(sourcesDir.resolve(".root"), root.toString());
            loadIndex();
        }
    }

    /** Pin a Maven or Gradle root to $JAVA_HOME, so per-project tools like
     *  sdkman or direnv choose its SDK instead of the newest JDK the server finds. */
    private Map<String, Object> pinnedProject(Path root) {
        String home = System.getenv("JAVA_HOME");
        if (home == null || home.isEmpty() || !Files.exists(Path.of(home, "release"))) return null;
        String type = null;
        if (Files.exists(root.resolve("pom.xml"))) type = "maven";
        for (String marker : List.of("settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts")) {
            if (type == null && Files.exists(root.resolve(marker))) type = "gradle";
        }
        if (type == null) return null;
        Map<String, Object> project = new LinkedHashMap<>();
        project.put("type", type);
        project.put("path", root.toUri().toString());
        project.put("java-home", home);
        return project;
    }

    /** Library sources the client knows by their file go back to the server's URI. */
    private Object toServerUris(Object value) {
        if (value instanceof Map<?, ?> map) {
            @SuppressWarnings("unchecked") Map<String, Object> object = (Map<String, Object>) map;
            for (Map.Entry<String, Object> entry : object.entrySet()) {
                if (isUriKey(entry.getKey()) && entry.getValue() instanceof String uri && uri.startsWith("file:")) {
                    Path path = pathOf(uri);
                    String archive = path == null ? null : archiveUriByPath.get(path.toString());
                    if (archive != null) entry.setValue(archive);
                } else {
                    entry.setValue(toServerUris(entry.getValue()));
                }
            }
        } else if (value instanceof List<?> list) {
            @SuppressWarnings("unchecked") List<Object> array = (List<Object>) list;
            array.replaceAll(this::toServerUris);
        }
        return value;
    }

    // Messages from the server ----------------------------------------------

    private void fromServer(Map<String, Object> message) throws IOException {
        Object id = message.get("id");
        Object method = message.get("method");
        if (method == null && id instanceof String key && key.startsWith("proxy-")) {
            CompletableFuture<Object> answer = pending.remove(key);
            if (answer != null) answer.complete(message.containsKey("error") ? null : message.get("result"));
            return;
        }
        if ("workspace/configuration".equals(method) && id != null) {
            send(toServer, response(id, configuration(message.get("params"))));
            return;
        }
        // A response may name library sources the client cannot read yet.
        boolean decompile = method == null;
        clientWriter.execute(() -> {
            try {
                toClientUris(message, decompile);
                send(toClient, message);
            } catch (Exception e) {
                trace("! " + e);
            }
        });
    }

    private Object configuration(Object params) {
        List<Object> answers = new ArrayList<>();
        if (params instanceof Map<?, ?> map && map.get("items") instanceof List<?> items) {
            for (Object item : items) {
                Object section = item instanceof Map<?, ?> m ? m.get("section") : null;
                answers.add(section(section instanceof String s ? s : null));
            }
        }
        return answers;
    }

    /** The settings of SECTION: a flat key, or an object of the keys below it. */
    Object section(String section) {
        if (section == null || section.isEmpty()) return new TreeMap<>(settings);
        if (settings.containsKey(section)) return settings.get(section);
        Map<String, Object> below = new TreeMap<>();
        String prefix = section + ".";
        settings.forEach((key, value) -> {
            if (key.startsWith(prefix)) below.put(key.substring(prefix.length()), value);
        });
        return below.isEmpty() ? null : below;
    }

    private Object toClientUris(Object value, boolean decompile) {
        if (value instanceof Map<?, ?> map) {
            @SuppressWarnings("unchecked") Map<String, Object> object = (Map<String, Object>) map;
            for (Map.Entry<String, Object> entry : object.entrySet()) {
                if (isUriKey(entry.getKey()) && entry.getValue() instanceof String uri && isArchiveUri(uri)) {
                    String file = decompile ? sourceFile(uri) : fileUriByArchiveUri.get(uri);
                    if (file != null) entry.setValue(file);
                } else {
                    entry.setValue(toClientUris(entry.getValue(), decompile));
                }
            }
        } else if (value instanceof List<?> list) {
            @SuppressWarnings("unchecked") List<Object> array = (List<Object>) list;
            array.replaceAll(v -> toClientUris(v, decompile));
        }
        return value;
    }

    /** Return the file: URI of library source URI, reading it from the server once. */
    private String sourceFile(String uri) {
        String known = fileUriByArchiveUri.get(uri);
        if (known != null || sourcesDir == null) return known;
        try {
            Object result = request("workspace/executeCommand",
                Map.of("command", "decompile", "arguments", List.of(uri))).get(20, TimeUnit.SECONDS);
            if (result instanceof Map<?, ?> map) result = map.get("code") != null ? map.get("code") : map.get("text");
            if (!(result instanceof String text)) return null;
            Path file = sourcesDir.resolve(sourcePath(uri));
            Files.createDirectories(file.getParent());
            if (!Files.exists(file) || !Files.readString(file).equals(text)) Files.writeString(file, text);
            remember(file, uri);
            Files.writeString(sourcesDir.resolve("index.tsv"), file + "\t" + uri + "\n",
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            return file.toUri().toString();
        } catch (Exception e) {
            trace("! decompile " + uri + ": " + e);
            return null;
        }
    }

    /** Where library source URI goes under the sources directory: the archive's
     *  name, then the entry.  A decompiled .class is Java. */
    static String sourcePath(String uri) {
        String decoded = URLDecoder.decode(uri);
        int bang = decoded.indexOf("!/");
        String archive, entry;
        if (bang >= 0) {
            archive = Path.of(decoded.substring(0, bang).replaceFirst("^[a-z]+:/*", "/")).getFileName().toString();
            entry = decoded.substring(bang + 2);
        } else {
            archive = "jrt";
            entry = decoded.replaceFirst("^jrt:/*", "");
        }
        if (entry.endsWith(".class")) entry = entry.substring(0, entry.length() - ".class".length()) + ".java";
        return archive + "/" + entry;
    }

    private void remember(Path file, String uri) {
        archiveUriByPath.put(file.toString(), uri);
        fileUriByArchiveUri.put(uri, file.toUri().toString());
    }

    /** Sources read by an earlier run stay open in editors: know them again. */
    private void loadIndex() throws IOException {
        Path index = sourcesDir.resolve("index.tsv");
        if (!Files.exists(index)) return;
        for (String line : Files.readAllLines(index)) {
            int tab = line.indexOf('\t');
            if (tab > 0 && Files.exists(Path.of(line.substring(0, tab)))) {
                remember(Path.of(line.substring(0, tab)), line.substring(tab + 1));
            }
        }
    }

    private CompletableFuture<Object> request(String method, Object params) throws IOException {
        String id = "proxy-" + proxyIds.incrementAndGet();
        CompletableFuture<Object> answer = new CompletableFuture<>();
        pending.put(id, answer);
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("jsonrpc", "2.0");
        message.put("id", id);
        message.put("method", method);
        message.put("params", params);
        send(toServer, message);
        return answer;
    }

    // Helpers --------------------------------------------------------------

    private static boolean isUriKey(String key) {
        return key.equals("uri") || key.equals("targetUri");
    }

    private static boolean isArchiveUri(String uri) {
        return uri.startsWith("jar:") || uri.startsWith("jrt:");
    }

    private static Path pathOf(String fileUri) {
        try {
            Path path = Path.of(URI.create(fileUri)).toAbsolutePath().normalize();
            return Files.exists(path) ? path.toRealPath() : path;
        } catch (Exception e) {
            return null;
        }
    }

    /** Add SETTINGS to INTO as flat dotted keys, whether nested or flat already. */
    static void flatten(String prefix, Object value, Map<String, Object> into) {
        if (value instanceof Map<?, ?> map) {
            map.forEach((key, v) -> flatten(prefix.isEmpty() ? key.toString() : prefix + "." + key, v, into));
        } else if (!prefix.isEmpty()) {
            if (value == null) into.remove(prefix); else into.put(prefix, value);
        }
    }

    private static Map<String, Object> response(Object id, Object result) {
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("jsonrpc", "2.0");
        message.put("id", id);
        message.put("result", result);
        return message;
    }

    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder();
        for (byte b : bytes) text.append(String.format("%02x", b));
        return text.toString();
    }

    private void trace(String line) {
        if (log != null) log.println(line);
    }

    // Framing --------------------------------------------------------------

    interface Handler { void handle(Map<String, Object> message) throws IOException; }

    @SuppressWarnings("unchecked")
    private void pump(InputStream input, Handler handler) {
        try (InputStream in = new BufferedInputStream(input)) {
            byte[] body;
            while ((body = readMessage(in)) != null) {
                String text = new String(body, StandardCharsets.UTF_8);
                trace((input == System.in ? "> " : "< ") + text);
                if (Json.parse(text) instanceof Map<?, ?> message) handler.handle((Map<String, Object>) message);
            }
        } catch (IOException e) {
            trace("! " + e);
        }
    }

    static byte[] readMessage(InputStream in) throws IOException {
        int length = -1;
        StringBuilder line = new StringBuilder();
        while (true) {
            int c = in.read();
            if (c < 0) return null;
            if (c == '\n') {
                String header = line.toString().trim();
                line.setLength(0);
                if (header.isEmpty()) {
                    if (length >= 0) break;
                    continue;
                }
                int colon = header.indexOf(':');
                if (colon > 0 && header.substring(0, colon).trim().equalsIgnoreCase("Content-Length")) {
                    length = Integer.parseInt(header.substring(colon + 1).trim());
                }
            } else if (c != '\r') {
                line.append((char) c);
            }
        }
        return in.readNBytes(length);
    }

    private void send(OutputStream out, Map<String, Object> message) throws IOException {
        byte[] body = Json.write(message).getBytes(StandardCharsets.UTF_8);
        synchronized (out) {
            out.write(("Content-Length: " + body.length + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.flush();
        }
    }

    // JSON -----------------------------------------------------------------

    /** Just enough JSON: objects keep their order, numbers keep their text. */
    static final class Json {
        private final String text;
        private int at;

        private Json(String text) { this.text = text; }

        static Object parse(String text) {
            Json json = new Json(text);
            Object value = json.value();
            json.space();
            if (json.at != text.length()) throw new IllegalArgumentException("trailing JSON at " + json.at);
            return value;
        }

        private void space() {
            while (at < text.length() && Character.isWhitespace(text.charAt(at))) at++;
        }

        private Object value() {
            space();
            char c = text.charAt(at);
            switch (c) {
                case '{': {
                    Map<String, Object> object = new LinkedHashMap<>();
                    at++;
                    space();
                    if (text.charAt(at) == '}') { at++; return object; }
                    while (true) {
                        space();
                        String key = string();
                        space();
                        expect(':');
                        object.put(key, value());
                        space();
                        if (text.charAt(at++) == '}') return object;
                    }
                }
                case '[': {
                    List<Object> array = new ArrayList<>();
                    at++;
                    space();
                    if (text.charAt(at) == ']') { at++; return array; }
                    while (true) {
                        array.add(value());
                        space();
                        if (text.charAt(at++) == ']') return array;
                    }
                }
                case '"': return string();
                case 't': at += 4; return Boolean.TRUE;
                case 'f': at += 5; return Boolean.FALSE;
                case 'n': at += 4; return null;
                default: {
                    int start = at;
                    while (at < text.length() && "+-0123456789.eE".indexOf(text.charAt(at)) >= 0) at++;
                    return new BigDecimal(text.substring(start, at));
                }
            }
        }

        private void expect(char c) {
            if (text.charAt(at++) != c) throw new IllegalArgumentException("expected " + c + " at " + (at - 1));
        }

        private String string() {
            expect('"');
            StringBuilder out = new StringBuilder();
            while (true) {
                char c = text.charAt(at++);
                if (c == '"') return out.toString();
                if (c != '\\') { out.append(c); continue; }
                char e = text.charAt(at++);
                switch (e) {
                    case 'n' -> out.append('\n');
                    case 't' -> out.append('\t');
                    case 'r' -> out.append('\r');
                    case 'b' -> out.append('\b');
                    case 'f' -> out.append('\f');
                    case 'u' -> { out.append((char) Integer.parseInt(text.substring(at, at + 4), 16)); at += 4; }
                    default -> out.append(e);
                }
            }
        }

        static String write(Object value) {
            StringBuilder out = new StringBuilder();
            write(value, out);
            return out.toString();
        }

        private static void write(Object value, StringBuilder out) {
            if (value == null) {
                out.append("null");
            } else if (value instanceof String s) {
                out.append('"');
                for (int i = 0; i < s.length(); i++) {
                    char c = s.charAt(i);
                    switch (c) {
                        case '"' -> out.append("\\\"");
                        case '\\' -> out.append("\\\\");
                        case '\n' -> out.append("\\n");
                        case '\r' -> out.append("\\r");
                        case '\t' -> out.append("\\t");
                        default -> {
                            if (c < 0x20) out.append(String.format("\\u%04x", (int) c)); else out.append(c);
                        }
                    }
                }
                out.append('"');
            } else if (value instanceof Map<?, ?> map) {
                out.append('{');
                boolean first = true;
                for (Map.Entry<?, ?> entry : map.entrySet()) {
                    if (!first) out.append(',');
                    first = false;
                    write(entry.getKey().toString(), out);
                    out.append(':');
                    write(entry.getValue(), out);
                }
                out.append('}');
            } else if (value instanceof Collection<?> list) {
                out.append('[');
                boolean first = true;
                for (Object item : list) {
                    if (!first) out.append(',');
                    first = false;
                    write(item, out);
                }
                out.append(']');
            } else if (value instanceof BigDecimal number) {
                out.append(number.toString());
            } else {
                out.append(value);
            }
        }
    }

    // URL decoding without java.net.URLDecoder's "+" means space.
    static final class URLDecoder {
        static String decode(String text) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            for (int i = 0; i < text.length(); i++) {
                char c = text.charAt(i);
                if (c == '%' && i + 2 < text.length()) {
                    bytes.write(Integer.parseInt(text.substring(i + 1, i + 3), 16));
                    i += 2;
                } else {
                    byte[] encoded = String.valueOf(c).getBytes(StandardCharsets.UTF_8);
                    bytes.write(encoded, 0, encoded.length);
                }
            }
            return bytes.toString(StandardCharsets.UTF_8);
        }
    }
}
