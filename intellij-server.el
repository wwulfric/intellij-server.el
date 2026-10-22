;;; intellij-server.el --- JetBrains' IntelliJ language server for Emacs -*- lexical-binding: t; -*-

;; Copyright (c) 2026 haidao

;; Author: haidao <wwulfric@gmail.com>
;; URL: https://github.com/wwulfric/intellij-server.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools, java, kotlin
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.
;;
;; Licensed under the MIT License; see the LICENSE file that comes with it.

;;; Commentary:
;; The IntelliJ language server is a headless IntelliJ IDEA that speaks LSP
;; over stdio.  JetBrains ships it inside its VS Code extension, and it
;; expects an IDE on the other end: it pulls flat, dotted settings, inserts
;; some completions through a command, asks its questions mid-refactoring
;; with `intellij/*' messages and names library sources with `jar:' and
;; `jrt:' URIs that only it can read.
;;
;; The protocol-level half is a proxy, proxy/IntellijServerProxy.java,
;; that clients start in place of the server.  It runs on the Java runtime
;; bundled with the server, starts the server (the EULA hash, persistent
;; index directories, the heap), answers its flat settings, pins the
;; project SDK and turns library sources into files.  Any LSP client can
;; use it as it is.
;;
;; This file installs the server, compiles the proxy and builds the
;; command, finds the project root and computes `initializationOptions';
;; it also shows the server's own questions, build log and license state,
;; which need the editor.  The eglot and lsp-bridge adapters connect those
;; to a client:
;;
;;   (require 'intellij-server-eglot)      ; M-x eglot in Java buffers
;;   (require 'intellij-server-lsp-bridge) ; lsp-bridge's Java servers
;;
;; The server needs an IntelliJ IDEA Ultimate (or All Products Pack)
;; license, found on its own when a JetBrains Account is signed in through
;; the IDE or Toolbox; `intellij-server-license' activates one otherwise.
;; Ported from intellij-server.nvim, which documents the protocol.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)

(defgroup intellij-server nil
  "JetBrains' IntelliJ language server."
  :group 'tools
  :prefix "intellij-server-")

;;;; Server release

(defconst intellij-server-version "1.0.27"
  "Server version that `intellij-server-install' downloads.")

(defconst intellij-server-build "263.7084.0"
  "IntelliJ build of `intellij-server-version'.")

(defconst intellij-server-base-url
  "https://download.jetbrains.com/language-server/intellij-server"
  "Where JetBrains publishes the server, per build.")

(defcustom intellij-server-directory (locate-user-emacs-file "intellij-server/")
  "Directory holding the installed server and its indexes."
  :type 'directory)

(defcustom intellij-server-program nil
  "The server's launcher, or nil for the one `intellij-server-install' put
under `intellij-server-directory'."
  :type '(choice (const :tag "Installed" nil) file))

(defcustom intellij-server-jvm-args nil
  "Extra JVM options for the server, such as (\"-Xmx8g\").
They follow the server's own vmoptions, so a heap size here wins over
the 2 GB it ships with."
  :type '(repeat string))

(defcustom intellij-server-java-home nil
  "JDK that runs the server, or nil for $JAVA_HOME, then the bundled one.
It does not choose the JDK the project compiles against; see
`intellij-server-projects'."
  :type '(choice (const :tag "Default" nil) directory))

;;;; Project

(defcustom intellij-server-root-markers
  '("pom.xml" "build.gradle" "build.gradle.kts" "settings.gradle"
    "settings.gradle.kts" "WORKSPACE" "WORKSPACE.bazel" ".idea")
  "Files whose directory the server can import as a project.
The topmost one below the repository root wins, so a module of a
multimodule build opens the whole build."
  :type '(repeat string))

(defcustom intellij-server-projects nil
  "Explicit project imports, overriding the server's marker detection.
Each entry is a plist with :type (\"maven\", \"gradle\", \"bazel\",
\"jps\" or \"json\") and :path, optionally :javaHome (the JDK to use
as the project SDK), :env and :systemProperties.  It can also be a
function of the project root returning that list.  Set it in
.dir-locals.el to pin one project's JDK."
  :type '(choice (repeat plist) function)
  :safe #'listp)

(defcustom intellij-server-build-tools nil
  "Build tool per folder that several build systems claim, as an alist
of (DIRECTORY . TOOL), TOOL being \"gradle\", \"maven\", \"bazel\" or
\"jps\".  The server refuses to import such a folder until told."
  :type '(alist :key-type directory :value-type string)
  :safe #'listp)

(defcustom intellij-server-default-sdk nil
  "JDK home the server resolves symbols against when a project pins none."
  :type '(choice (const :tag "None" nil) directory)
  :safe #'stringp)

;;;; Settings

(defcustom intellij-server-settings nil
  "Workspace settings over the proxy's defaults, as flat dotted keys.
For example ((\"jetbrains.kotlin.hints.parameters\" . :json-false)).
Values are JSON: t, :json-false, numbers or strings.  The proxy turns
every inlay hint category on but call chains and a few rarer ones; see
DEFAULT_SETTINGS in proxy/IntellijServerProxy.java."
  :type '(alist :key-type string :value-type sexp))

(defun intellij-server--object (alist)
  "Return ALIST of string keys as a hash table, which encodes as an object."
  (let ((table (make-hash-table :test #'equal)))
    (pcase-dolist (`(,key . ,value) alist)
      (puthash key value table))
    table))

;;;; Installation

(defun intellij-server--platform ()
  "Return the server's name for this platform, such as \"mac-aarch64\"."
  (let ((os (pcase system-type
              ('darwin "mac") ('gnu/linux "linux") ('windows-nt "win")))
        (arch (cond ((string-match-p "\\`\\(aarch64\\|arm64\\)" system-configuration)
                     "aarch64")
                    ((string-match-p "\\`\\(x86_64\\|amd64\\)" system-configuration)
                     "amd64"))))
    (unless (and os arch)
      (user-error "The IntelliJ server is not published for %s" system-configuration))
    (format "%s-%s" os arch)))

(defun intellij-server-download-url ()
  "Return the address of the server's archive for this platform."
  (format "%s/%s/intellij-server-%s-%s.vsix" intellij-server-base-url
          intellij-server-build intellij-server-version (intellij-server--platform)))

(defun intellij-server--server-directory ()
  "Return the installed server's directory, which holds bin/ and EULA.txt."
  (if intellij-server-program
      (file-name-directory (directory-file-name
                            (file-name-directory (expand-file-name intellij-server-program))))
    (expand-file-name "server/" intellij-server-directory)))

(defun intellij-server-executable ()
  "Return the server's launcher."
  (or (and intellij-server-program (expand-file-name intellij-server-program))
      (expand-file-name (if (eq system-type 'windows-nt)
                            "bin/intellij-server.exe"
                          "bin/intellij-server")
                        (intellij-server--server-directory))))

(defun intellij-server--version-file ()
  (expand-file-name ".version" intellij-server-directory))

(defun intellij-server--release ()
  (format "%s+%s" intellij-server-version intellij-server-build))

(defun intellij-server-installed-p ()
  "Return non-nil when the server can be started."
  (and (file-executable-p (intellij-server-executable))
       (or intellij-server-program
           (with-temp-buffer
             (ignore-errors (insert-file-contents (intellij-server--version-file)))
             (equal (string-trim (buffer-string)) (intellij-server--release))))))

(defun intellij-server--run (name program args on-success)
  "Run PROGRAM with ARGS in the install log, then ON-SUCCESS if it exits 0.
NAME says what it does in the messages."
  (let ((buffer (get-buffer-create "*intellij-server-install*")))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format "\n$ %s %s\n" program (string-join args " "))))
    (make-process
     :name (concat "intellij-server-" name)
     :buffer buffer
     :command (cons program args)
     :connection-type 'pipe
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (if (zerop (process-exit-status process))
             (funcall on-success)
           (display-buffer buffer)
           (message "[intellij-server] %s failed; run M-x intellij-server-install \
again to resume" name)))))))

;;;###autoload
(defun intellij-server-install (&optional force)
  "Download the server from JetBrains and unpack it.
The archive is about 370 MB; an interrupted download resumes on the
next call.  With prefix argument FORCE, reinstall the current version."
  (interactive "P")
  (dolist (tool '("curl" "unzip"))
    (unless (executable-find tool)
      (user-error "`%s' is needed to install the server" tool)))
  (if (and (not force) (intellij-server-installed-p))
      (message "[intellij-server] %s is installed" (intellij-server--release))
    (let* ((directory (file-name-as-directory (expand-file-name intellij-server-directory)))
           (archive (expand-file-name (format "intellij-server-%s.vsix" (intellij-server--release))
                                      directory)))
      (make-directory directory t)
      ;; Partial archives of other releases cannot be resumed.
      (dolist (stale (file-expand-wildcards (expand-file-name "*.vsix" directory)))
        (unless (string= stale archive) (delete-file stale)))
      (message "[intellij-server] Downloading %s…" (intellij-server--release))
      (intellij-server--run
       "download" "curl"
       ;; -C - resumes, and --retry-all-errors also retries a transfer
       ;; closed midway, which plain --retry does not.
       (list "-fSL" "--retry" "5" "--retry-all-errors" "--retry-delay" "2"
             "-C" "-" "-o" archive (intellij-server-download-url))
       (lambda ()
         (intellij-server--run
          "unpack" "unzip" (list "-qo" archive "extension/server/*" "-d" directory)
          (lambda ()
            (let ((target (expand-file-name "server" directory)))
              (when (file-directory-p target) (delete-directory target t))
              (rename-file (expand-file-name "extension/server" directory) target)
              (delete-directory (expand-file-name "extension" directory) t)
              (delete-file archive)
              (set-file-modes (expand-file-name "bin/intellij-server" target) #o755)
              (with-temp-file (intellij-server--version-file)
                (insert (intellij-server--release) "\n"))
              (intellij-server-proxy-classes)
              (message "[intellij-server] Installed %s" (intellij-server--release))))))))))

;;;; Command

(defconst intellij-server-proxy-source
  (expand-file-name "proxy/IntellijServerProxy.java"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Source of the proxy that clients start in place of the server.")

(defun intellij-server-data-directory ()
  "Return where the server keeps its configuration, indexes and logs.
Without it they would go to the temporary directory and be rebuilt."
  (expand-file-name "data/" intellij-server-directory))

(defun intellij-server--jbr (program)
  "Return PROGRAM of the Java runtime bundled with the server."
  (let ((home (expand-file-name "jbr/Contents/Home" (intellij-server--server-directory))))
    (unless (file-directory-p home)
      (setq home (expand-file-name "jbr" (intellij-server--server-directory))))
    (expand-file-name (concat "bin/" program (if (eq system-type 'windows-nt) ".exe" ""))
                      home)))

(defun intellij-server-proxy-classes ()
  "Return the directory of the compiled proxy, compiling it first if needed.
The JDK bundled with the server compiles it into a directory named after
the source's hash, so an edited source is compiled again."
  (let* ((hash (with-temp-buffer
                 (insert-file-contents-literally intellij-server-proxy-source)
                 (secure-hash 'sha1 (current-buffer))))
         (classes (expand-file-name (format "proxy/%s/" (substring hash 0 12))
                                    intellij-server-directory)))
    (unless (file-exists-p (expand-file-name "IntellijServerProxy.class" classes))
      (make-directory classes t)
      (with-temp-buffer
        (unless (zerop (call-process (intellij-server--jbr "javac") nil t nil
                                     "--release" "21" "-d" classes
                                     intellij-server-proxy-source))
          (delete-directory classes t)
          (error "[intellij-server] Could not compile the proxy: %s" (buffer-string)))))
    classes))

(defun intellij-server-command ()
  "Return the command that starts the server behind its proxy, over stdio."
  (unless (intellij-server-installed-p)
    (user-error "The IntelliJ server is not installed; run M-x intellij-server-install"))
  (append (list (intellij-server--jbr "java")
                ;; The proxy only passes messages along.
                "-XX:+UseSerialGC" "-XX:TieredStopAtLevel=1" "-Xmx256m"
                "-cp" (intellij-server-proxy-classes) "IntellijServerProxy"
                "--server" (directory-file-name (intellij-server--server-directory))
                "--data" (directory-file-name (intellij-server-data-directory)))
          (when intellij-server-java-home
            (list "--java-home" (expand-file-name intellij-server-java-home)))
          (mapcan (lambda (arg) (list "--jvm-arg" arg)) (copy-sequence intellij-server-jvm-args))))

;;;; Project root and initialization

(defun intellij-server--marker-p (directory)
  (cl-some (lambda (marker) (file-exists-p (expand-file-name marker directory)))
           intellij-server-root-markers))

(defun intellij-server-project-root (file)
  "Return the root the server should import for FILE.
That is the topmost directory with a build marker, searched up to the
repository holding FILE and no further, so one stray marker above it
cannot capture everything beneath; failing that, the repository, then
FILE's directory."
  (let* ((start (file-name-directory (expand-file-name file)))
         (top (locate-dominating-file
               start (lambda (dir)
                       (cl-some (lambda (vcs) (file-directory-p (expand-file-name vcs dir)))
                                '(".git" ".hg" ".svn" ".jj")))))
         (dir start) root)
    (while dir
      (when (intellij-server--marker-p dir) (setq root dir))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (unless (or (equal parent dir)
                              (and top (file-equal-p dir top)))
                    parent))))
    (file-name-as-directory (expand-file-name (or root top start)))))

(defun intellij-server--project-local (root variable)
  "Return VARIABLE's value for ROOT, honoring its .dir-locals.el."
  (with-temp-buffer
    (setq default-directory root)
    (hack-dir-local-variables-non-file-buffer)
    (symbol-value variable)))

(defun intellij-server--uri (path)
  (concat "file://" (url-hexify-string (directory-file-name (expand-file-name path))
                                       url-path-allowed-chars)))

(defun intellij-server--projects (root)
  "Return the projects to import for ROOT, or nil to let the server decide.
Without a list, the proxy pins a Maven or Gradle build to $JAVA_HOME."
  (let ((projects (intellij-server--project-local root 'intellij-server-projects)))
    (if (functionp projects) (funcall projects root) projects)))

(defun intellij-server-initialization-options (root)
  "Return the server's `initializationOptions' for project ROOT."
  (let ((projects (intellij-server--projects root))
        (tools (intellij-server--project-local root 'intellij-server-build-tools))
        (sdk (intellij-server--project-local root 'intellij-server-default-sdk))
        (settings (intellij-server--project-local root 'intellij-server-settings)))
    (append
     ;; The server's protocol additions and actions resolved only when run,
     ;; as the VS Code extension asks for.
     (list :intellijExtensions t :lazyIntentions t)
     (when projects
       (list :projects
             (vconcat
              (mapcar (lambda (p)
                        (let ((path (plist-get p :path))
                              (home (plist-get p :javaHome)))
                          ;; The server reads kebab-case names.
                          (append (list :type (plist-get p :type)
                                        :path (if (string-match-p "\\`[a-z]+://" path) path
                                                (intellij-server--uri path)))
                                  (when home
                                    (list :java-home (directory-file-name (expand-file-name home))))
                                  (when-let* ((env (plist-get p :env))) (list :env env))
                                  (when-let* ((props (plist-get p :systemProperties)))
                                    (list :system-properties props)))))
                      projects))))
     (when tools
       (list :buildTools
             (intellij-server--object
              (mapcar (lambda (entry) (cons (intellij-server--uri (car entry)) (cdr entry)))
                      tools))))
     (when sdk
       (list :defaultSdk (directory-file-name (expand-file-name sdk))))
     ;; For the proxy, which answers the server's settings requests.
     (when settings
       (list :settings (intellij-server--object settings))))))

;;;; Library sources

(defun intellij-server-source-root (file)
  "Return the root of the project whose library source FILE is, if it is one.
The proxy writes the sources a project reads under the data directory,
in a folder whose .root file names the project."
  (when-let* ((sources (expand-file-name "sources/" (intellij-server-data-directory)))
              ((file-in-directory-p file sources))
              (folder (locate-dominating-file file ".root"))
              (root (with-temp-buffer
                      (insert-file-contents (expand-file-name ".root" folder))
                      (string-trim (buffer-string))))
              ((file-directory-p root)))
    (file-name-as-directory root)))

(defun intellij-server-source-project (directory)
  "Return the project of the library source in DIRECTORY, if it is one.
Found that way, the project's language server goes on serving the
source, so navigation works in it.  For `project-find-functions'."
  (when-let* ((root (intellij-server-source-root directory)))
    (project-current nil root)))

(add-hook 'project-find-functions #'intellij-server-source-project -50)

(defun intellij-server--source-read-only ()
  "Visit library sources read-only: they are the server's copy."
  (when (and buffer-file-name (intellij-server-source-root buffer-file-name))
    (setq buffer-read-only t)))

(add-hook 'find-file-hook #'intellij-server--source-read-only)

;;;; The server's questions

(defun intellij-server-choose-action (title entries run)
  "Ask which of ENTRIES continues the action TITLE, and pass its command to RUN.
ENTRIES are the `intellij/chooseAction' plists with :name and :command."
  (let* ((choices (mapcar (lambda (e) (cons (plist-get e :name) e)) entries))
         (name (completing-read (concat (or title "Choose") ": ") choices nil t)))
    (when-let* ((entry (cdr (assoc name choices))))
      (funcall run (plist-get entry :command)))))

(defun intellij-server--location-file (location)
  (let ((uri (plist-get location :uri)))
    (if (string-prefix-p "file://" uri)
        (url-unhex-string (substring uri (length "file://")))
      uri)))

(defun intellij-server-show-conflicts (params)
  "Show the conflicts of a refactoring in PARAMS and ask whether to go ahead.
Returns the `intellij/showConflicts' answer."
  (let ((buffer (get-buffer-create "*intellij-server conflicts*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or (plist-get params :title) "Conflicts") "\n\n")
        (seq-doseq (conflict (plist-get params :conflicts))
          (let ((text (mapconcat #'string-trim (plist-get conflict :messages) " "))
                (location (plist-get conflict :location)))
            (if location
                (let ((start (plist-get (plist-get location :range) :start)))
                  (insert (format "%s:%d:%d: %s\n" (intellij-server--location-file location)
                                  (1+ (plist-get start :line))
                                  (1+ (plist-get start :character)) text)))
              (insert text "\n")))))
      (compilation-mode))
    (display-buffer buffer)
    (list :decision (if (yes-or-no-p (format "%s? "
                                             (or (plist-get params :continueLabel) "Continue")))
                        "continue" "cancel"))))

(defun intellij-server-copy-to-clipboard (params)
  "Put the text of PARAMS on the kill ring and the clipboard."
  (when-let* ((content (plist-get params :content)))
    (kill-new content)
    (message "[intellij-server] Copied to the clipboard")))

(defvar intellij-server--reported-folders nil
  "Blocked folders already reported, so each is reported once.")

(defun intellij-server-import-status (params)
  "Report the folders in PARAMS that the server will not import on its own."
  (let ((blocked (append (plist-get params :blockedFolders) nil)))
    (setq intellij-server--reported-folders
          (cl-intersection intellij-server--reported-folders
                           (mapcar (lambda (f) (plist-get f :folderUri)) blocked)
                           :test #'equal))
    (dolist (folder blocked)
      (let ((uri (plist-get folder :folderUri)))
        (unless (member uri intellij-server--reported-folders)
          (push uri intellij-server--reported-folders)
          (message "[intellij-server] Import of %s is blocked (%s)%s" uri
                   (plist-get folder :reason)
                   (if (equal (plist-get folder :reason) "ambiguousBuildSystem")
                       (format "; choose one of %s in `intellij-server-build-tools' and restart"
                               (string-join (append (plist-get folder :candidates) nil) ", "))
                     "")))))))

;;;; Build log

(defcustom intellij-server-build-log-display 'failure
  "When to show the build log, streamed during imports and builds."
  :type '(choice (const :tag "When a build fails" failure)
                 (const :tag "When a build starts" start)
                 (const :tag "Never" nil)))

(defun intellij-server-build-log-buffer ()
  (or (get-buffer "*intellij-server build*")
      (with-current-buffer (get-buffer-create "*intellij-server build*")
        (special-mode)
        (current-buffer))))

;;;###autoload
(defun intellij-server-build-log ()
  "Show the log of the server's imports and builds."
  (interactive)
  (display-buffer (intellij-server-build-log-buffer)))

(defun intellij-server-import-log (params)
  "Append PARAMS of an `intellij/importLog' notification to the build log."
  (let ((tool (or (plist-get params :tool) "Build"))
        (text (plist-get params :message)))
    (with-current-buffer (intellij-server-build-log-buffer)
      (let ((inhibit-read-only t)
            (follow (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (when (eq (plist-get params :started) t)
            (insert (format "\n── %s started ──\n" tool)))
          (when text
            (insert text (if (string-suffix-p "\n" text) "" "\n"))))
        (when follow (goto-char (point-max)))))
    (cond ((eq (plist-get params :started) t)
           (message "[intellij-server] %s started" tool)
           (when (eq intellij-server-build-log-display 'start) (intellij-server-build-log)))
          ((eq (plist-get params :failed) t)
           (message "[intellij-server] %s failed; see M-x intellij-server-build-log" tool)
           (when intellij-server-build-log-display (intellij-server-build-log)))
          ((eq (plist-get params :succeeded) t)
           (message "[intellij-server] %s finished" tool)))))

;;;; License

(defvar intellij-server--license-condition nil
  "What the user was last told about the license.")

(defun intellij-server-license-state (state)
  "Warn when the server's license STATE, a `jetbrains/licensing/state', is lost."
  (let* ((active (plist-get state :activeLicense))
         (condition
          (cond ((equal (plist-get active :status) "Valid") nil)
                ((eq (plist-get state :featuresDeclined) t)
                 (format "Running without a license (%s): every request is refused. \
Activate one with M-x intellij-server-license."
                         (or (plist-get state :parkedReason) "StartedUnlicensed")))
                ((plist-get state :graceDeadline)
                 (format "The license was lost; the server keeps working until %s."
                         (format-time-string
                          "%F %R" (/ (plist-get state :graceDeadline) 1000)))))))
    (unless (equal condition intellij-server--license-condition)
      (if condition
          (display-warning 'intellij-server condition)
        (when intellij-server--license-condition
          (message "[intellij-server] License active: %s" (plist-get active :product))))
      (setq intellij-server--license-condition condition))))

;;;###autoload
(defun intellij-server-license (subcommand)
  "Run the server's license SUBCOMMAND: status, login, activate or trial.
Login signs in to a JetBrains Account in the browser.  The server finds
an account already signed in through the IDE or Toolbox by itself."
  (interactive (list (completing-read "License: " '("status" "login" "activate" "trial")
                                      nil t nil nil "status")))
  (let ((default-directory (expand-file-name "~/")))
    (unless (intellij-server-installed-p)
      (user-error "The IntelliJ server is not installed; run M-x intellij-server-install"))
    (make-comint-in-buffer "intellij-server-license" "*intellij-server license*"
                           (intellij-server-executable) nil "license" subcommand)
    (pop-to-buffer "*intellij-server license*")))

;;;; Maintenance

;;;###autoload
(defun intellij-server-log ()
  "Open the server's own log."
  (interactive)
  (find-file-read-only (expand-file-name "log/intellij-server.log" (intellij-server-data-directory)))
  (goto-char (point-max)))

(provide 'intellij-server)
;;; intellij-server.el ends here
