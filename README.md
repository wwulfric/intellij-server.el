# intellij-server.el

JetBrains' [IntelliJ language server](https://blog.jetbrains.com/idea/2026/10/intellij-idea-s-java-and-kotlin-for-cursor-and-vs-code-hits-1-0/)
in Emacs: IntelliJ IDEA's own analysis of Java and Kotlin through
[eglot](https://www.gnu.org/software/emacs/manual/html_mono/eglot.html) or
[lsp-bridge](https://github.com/manateelazycat/lsp-bridge).

The server is a headless IntelliJ IDEA that speaks LSP, written for JetBrains'
VS Code extension, and it expects that client's help: it will not start
without its EULA hash, reads settings as flat dotted keys, names library
sources with `jar:` URIs only it can read, inserts Kotlin completions through
a command and asks questions mid-refactoring with messages of its own. This
package supplies those pieces, after
[intellij-server.nvim](https://github.com/AlexandrosAlexiou/intellij-server.nvim).

Not affiliated with JetBrains. The server needs an **IntelliJ IDEA Ultimate**
or **All Products Pack** license, or the 30-day trial.

## What you get

- Completion with auto-import, Kotlin items inserted by the server with their
  parentheses and caret
- Diagnostics from IntelliJ's compiler and inspections
- Definitions, implementations, references, type hierarchy, also into
  dependency and JDK sources, and on from there
- Refactorings and quick fixes (extract, inline, split, …), whose questions
  come up in the minibuffer and whose follow-up renames start on their own
- Formatting with IntelliJ's code style, configurable with `.editorconfig`
- Inlay hints, folding, code lenses
- Maven, Gradle, Bazel and `.idea` projects, with the import log in
  `M-x intellij-server-build-log`

## How it works

```
eglot / lsp-bridge / any LSP client
        │  stdio
        ▼
proxy/IntellijServerProxy.java   ← runs on the server's bundled Java
        │  stdio
        ▼
intellij-server --stdio          ← JetBrains' server
```

The **proxy** handles what every client would otherwise have to: the launch
(EULA hash, persistent index directory, JVM options), the server's settings
requests, pinning a Maven or Gradle project's SDK to `$JAVA_HOME`, and library
sources, which it turns into read-only files under the data directory. It runs
on the Java runtime that comes with the server, so nothing else is needed; the
package compiles it with that runtime's `javac` on first use.

The **Elisp** keeps what needs the editor: Kotlin completions inserted by the
server's command, the refactoring questions, the build log and the license
state. `intellij-server.el` is shared; `intellij-server-eglot.el` and
`intellij-server-lsp-bridge.el` connect it to a client.

## Install

Requires Emacs 30.1+, `curl` and `unzip`, on macOS, Linux or Windows (x86_64
or ARM64).

### With use-package

`use-package` and its `:vc` keyword come with Emacs 30:

```elisp
(use-package intellij-server
  :vc (:url "https://github.com/wwulfric/intellij-server.el")
  :custom
  ;; Where the server (about 1 GB unpacked), its indexes and sources live.
  (intellij-server-directory (locate-user-emacs-file "intellij-server/")))
```

### From a Git checkout

Clone the repository, or add it as a submodule of a configuration kept in
Git:

```sh
git clone https://github.com/wwulfric/intellij-server.el ~/.emacs.d/lisp/intellij-server
# or, in your configuration's repository:
git submodule add https://github.com/wwulfric/intellij-server.el lisp/intellij-server
```

Then put it on the `load-path` and load the adapter for your client (see
[Use](#use)):

```elisp
(add-to-list 'load-path (locate-user-emacs-file "lisp/intellij-server"))
(setq intellij-server-directory (locate-user-emacs-file "intellij-server/"))
(require 'intellij-server-lsp-bridge)   ; or 'intellij-server-eglot
```

Keep the checkout whole: the proxy is compiled from `proxy/` next to the
Lisp files.  Update with `git pull`, or `git submodule update --remote`.

### The server

However the package is installed, download the server (about 370 MB; an interrupted download resumes):

```
M-x intellij-server-install
```

### License

If a JetBrains Account with a suitable license is signed in through the IDE or
Toolbox, the server finds it. Otherwise:

```
M-x intellij-server-license   ; status, login, activate or trial
```

## Use

### eglot

```elisp
(require 'intellij-server-eglot)
(add-hook 'java-ts-mode-hook #'eglot-ensure)
```

The adapter registers the server for `java-mode`, `java-ts-mode`,
`kotlin-mode` and `kotlin-ts-mode` (`intellij-server-eglot-modes`).

### lsp-bridge

```elisp
(require 'intellij-server-lsp-bridge)
```

Once the server is installed it serves `.java`, `.kt` and `.kts` files in place
of jdtls and kotlin-language-server. It relies on lsp-bridge features that are
not upstream yet — `emacsHandlers`, `completionItemCommands`,
`window/showDocument` and `InsertReplaceEdit` completions — available in
[wwulfric/lsp-bridge](https://github.com/wwulfric/lsp-bridge).

### Any other LSP client

Start the command `(intellij-server-command)` returns. Everything the proxy
handles works; Kotlin completions need the client to run a completion item's
command, and the `intellij/*` questions need handlers of its own.

## Configuration

| Variable | Default | |
|---|---|---|
| `intellij-server-directory` | `~/.emacs.d/intellij-server/` | Server, indexes, sources |
| `intellij-server-jvm-args` | `nil` | Server JVM options, e.g. `("-Xmx8g")` |
| `intellij-server-java-home` | `nil` | JDK that runs the server; `$JAVA_HOME`, then the bundled one |
| `intellij-server-settings` | `nil` | Settings over the proxy's defaults, flat keys: `(("jetbrains.kotlin.hints.parameters" . :json-false))` |
| `intellij-server-projects` | `nil` | Explicit imports, e.g. to pin a project's JDK |
| `intellij-server-build-tools` | `nil` | Build tool for a folder several claim |
| `intellij-server-default-sdk` | `nil` | JDK for symbol resolution when a project pins none |
| `intellij-server-build-log-display` | `failure` | When to show the build log |

The project settings are safe in `.dir-locals.el`:

```elisp
((nil . ((intellij-server-projects
          . ((:type "maven" :path "/path/to/project"
              :javaHome "/Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home"))))))
```

Without them, a Maven or Gradle project is pinned to `$JAVA_HOME`, so sdkman,
mise or direnv choose its SDK.

## Commands

| Command | |
|---|---|
| `intellij-server-install` | Download the server; with a prefix argument, reinstall |
| `intellij-server-license` | License status, sign-in, activation code or trial |
| `intellij-server-build-log` | Maven and Gradle import output |
| `intellij-server-log` | The server's own log |

## Notes

- One server per project: two editors on the same project cannot share its
  index.
- The server is heavy, a full IntelliJ backend. Raise its heap with
  `intellij-server-jvm-args` if it runs out of memory on a large project.

## Tests

```sh
emacs -Q --batch -L . -l test/intellij-server-tests.el -f ert-run-tests-batch-and-exit
```

The proxy test runs it against a fake server; it needs an installed server's
JDK (set `INTELLIJ_SERVER_DIRECTORY` if it is not in the default place) and
`python3`, and is skipped otherwise.

## License

MIT; see [LICENSE](LICENSE).
