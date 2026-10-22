;;; intellij-server-tests.el --- IntelliJ language server wrapper tests -*- lexical-binding: t; -*-

;; Copyright (c) 2026 haidao
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.
;;
;; Licensed under the MIT License; see the LICENSE file that comes with it.

;; Run: emacs -Q --batch -L . -l test/intellij-server-tests.el -f ert-run-tests-batch-and-exit
;; The proxy test needs the server's bundled JDK (M-x intellij-server-install)
;; and python3, which runs a fake server.  Set INTELLIJ_SERVER_DIRECTORY when
;; `intellij-server-directory' is not the default.
(require 'ert)
(require 'cl-lib)
(require 'intellij-server-eglot)

(defmacro intellij-server-test-with-directory (var &rest body)
  "Bind VAR to a fresh temporary directory for BODY, then delete it."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (file-truename (make-temp-file "intellij-server-test" t)))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun intellij-server-test-touch (directory &rest files)
  "Create FILES, relative names, under DIRECTORY."
  (dolist (file files)
    (let ((path (expand-file-name file directory)))
      (make-directory (file-name-directory path) t)
      (write-region "" nil path))))

;;;; Install and launch

(ert-deftest intellij-server-installed-p-checks-release ()
  (intellij-server-test-with-directory dir
    (let ((intellij-server-directory dir)
          (intellij-server-program nil)
          (bin (expand-file-name "server/bin/intellij-server" dir)))
      (intellij-server-test-touch dir "server/bin/intellij-server")
      (set-file-modes bin #o755)
      (should-not (intellij-server-installed-p))
      (with-temp-file (expand-file-name ".version" dir) (insert "0.0.1+1\n"))
      (should-not (intellij-server-installed-p))
      (with-temp-file (expand-file-name ".version" dir)
        (insert (format "%s+%s\n" intellij-server-version intellij-server-build)))
      (should (intellij-server-installed-p)))))

(ert-deftest intellij-server-download-url-names-platform ()
  (let ((system-type 'darwin)
        (system-configuration "aarch64-apple-darwin24.0.0"))
    (should (equal (intellij-server-download-url)
                   (format "%s/%s/intellij-server-%s-mac-aarch64.vsix" intellij-server-base-url
                           intellij-server-build intellij-server-version)))))

(ert-deftest intellij-server-command-starts-proxy ()
  (intellij-server-test-with-directory dir
    (let ((intellij-server-directory dir)
          (intellij-server-program nil)
          (intellij-server-java-home "/jdk")
          (intellij-server-jvm-args '("-Xmx8g" "-Dx=1")))
      (cl-letf (((symbol-function 'intellij-server-installed-p) #'always)
                ((symbol-function 'intellij-server-proxy-classes) (lambda () "/classes/")))
        (let ((command (intellij-server-command)))
          (should (string-suffix-p "jbr/bin/java" (car command)))
          (should (equal (member "-cp" command) (append '("-cp" "/classes/" "IntellijServerProxy")
                                                         (nthcdr 3 (member "-cp" command)))))
          (should (equal (cadr (member "--server" command)) (concat dir "server")))
          (should (equal (cadr (member "--data" command)) (concat dir "data")))
          (should (equal (cadr (member "--java-home" command)) "/jdk"))
          (should (equal (last command 4) '("--jvm-arg" "-Xmx8g" "--jvm-arg" "-Dx=1"))))))))

;;;; Project

(ert-deftest intellij-server-root-is-topmost-build-in-repository ()
  (intellij-server-test-with-directory dir
    (make-directory (expand-file-name "repo/.git" dir) t)
    (intellij-server-test-touch dir "pom.xml" "repo/pom.xml" "repo/core/pom.xml"
                                "repo/core/src/main/java/A.java")
    ;; The stray pom.xml above the repository does not capture it.
    (should (equal (intellij-server-project-root
                    (expand-file-name "repo/core/src/main/java/A.java" dir))
                   (expand-file-name "repo/" dir)))))

(ert-deftest intellij-server-root-without-marker-is-repository ()
  (intellij-server-test-with-directory dir
    (make-directory (expand-file-name "repo/.git" dir) t)
    (intellij-server-test-touch dir "repo/src/A.java")
    (should (equal (intellij-server-project-root (expand-file-name "repo/src/A.java" dir))
                   (expand-file-name "repo/" dir)))))

(ert-deftest intellij-server-initialization-options ()
  (intellij-server-test-with-directory dir
    (intellij-server-test-touch dir "app/pom.xml")
    (let ((intellij-server-projects nil)
          (intellij-server-build-tools `((,(concat dir "app") . "maven")))
          (intellij-server-default-sdk nil)
          (intellij-server-settings '(("jetbrains.kotlin.hints.parameters" . :json-false))))
      (let ((options (intellij-server-initialization-options (concat dir "app/"))))
        (should (eq (plist-get options :intellijExtensions) t))
        (should (eq (plist-get options :lazyIntentions) t))
        ;; The proxy pins $JAVA_HOME itself.
        (should-not (plist-member options :projects))
        (should (equal (hash-table-keys (plist-get options :buildTools))
                       (list (intellij-server--uri (concat dir "app")))))
        (should (eq (gethash "jetbrains.kotlin.hints.parameters" (plist-get options :settings))
                    :json-false))))))

(ert-deftest intellij-server-explicit-projects ()
  (intellij-server-test-with-directory dir
    (let ((intellij-server-projects
           (list (list :type "gradle" :path "file:///x" :javaHome "/jdk/")))
          (intellij-server-build-tools nil)
          (intellij-server-settings nil))
      (let ((options (intellij-server-initialization-options dir)))
        (should (equal (append (plist-get options :projects) nil)
                       '((:type "gradle" :path "file:///x" :java-home "/jdk"))))
        (should-not (plist-member options :settings))))))

;;;; Library sources

(ert-deftest intellij-server-source-root ()
  (intellij-server-test-with-directory dir
    (let ((intellij-server-directory dir)
          (folder (expand-file-name "data/sources/0123456789abcdef/" dir)))
      (make-directory (expand-file-name "proj" dir))
      (intellij-server-test-touch folder "lib.jar/org/A.java")
      (with-temp-file (expand-file-name ".root" folder) (insert dir "proj"))
      (should (equal (intellij-server-source-root (expand-file-name "lib.jar/org/A.java" folder))
                     (concat dir "proj/")))
      (should-not (intellij-server-source-root (expand-file-name "proj/A.java" dir)))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "lib.jar/org/A.java" folder))
        (intellij-server--source-read-only)
        (should buffer-read-only)))))

;;;; The proxy

(defconst intellij-server-test-fake-server "#!/usr/bin/env python3
# Answers like the IntelliJ server, and reports what it was sent.
import json, sys
inp, out = sys.stdin.buffer, sys.stdout.buffer
state = {'init': None, 'config': None, 'didOpen': None}
JAR = 'jar:///m2/lib-sources.jar!/org/A.java'
def read():
    length = None
    while True:
        line = inp.readline()
        if not line: sys.exit(0)
        line = line.strip()
        if not line:
            if length is not None: break
            continue
        key, value = line.decode().split(':', 1)
        if key.lower() == 'content-length': length = int(value)
    return json.loads(inp.read(length))
def send(msg):
    body = json.dumps(msg).encode()
    out.write(b'Content-Length: %d\\r\\n\\r\\n' % len(body) + body)
    out.flush()
def answer(m, result):
    send({'jsonrpc': '2.0', 'id': m['id'], 'result': result})
while True:
    m = read()
    method = m.get('method')
    if method == 'initialize':
        state['init'] = m['params'].get('initializationOptions')
        answer(m, {'capabilities': {}})
        send({'jsonrpc': '2.0', 'id': 'c1', 'method': 'workspace/configuration',
              'params': {'items': [{'section': 'jetbrains.java.hints'}]}})
    elif method is None and m.get('id') == 'c1':
        state['config'] = m.get('result')
    elif method == 'textDocument/didOpen':
        state['didOpen'] = m['params']['textDocument']['uri']
    elif method == 'textDocument/definition':
        answer(m, [{'uri': JAR, 'range': {'start': {'line': 0, 'character': 6},
                                          'end': {'line': 0, 'character': 7}}}])
    elif method == 'workspace/executeCommand':
        p = m['params']
        answer(m, {'code': 'class A {}\\n'} if p == {'command': 'decompile', 'arguments': [JAR]} else None)
    elif method == 'test/state':
        answer(m, state)
    elif method == 'shutdown':
        answer(m, None)
    elif method == 'exit':
        sys.exit(0)
"
  "A server that answers like the IntelliJ one and reports what it got.")

(defun intellij-server-test--jbr (program)
  "Return PROGRAM of the installed server's bundled JDK, or nil."
  (let ((intellij-server-directory (or (getenv "INTELLIJ_SERVER_DIRECTORY")
                                       intellij-server-directory))
        (intellij-server-program nil))
    (let ((path (intellij-server--jbr program)))
      (and (file-executable-p path) path))))

(defun intellij-server-test--send (process message)
  (let ((body (encode-coding-string (json-serialize message :null-object nil) 'utf-8)))
    (process-send-string process (format "Content-Length: %d\r\n\r\n" (length body)))
    (process-send-string process body)))

(defun intellij-server-test--receive (buffer id)
  "Return the message with ID from the proxy's output in BUFFER, waiting for it.
Every message read so far is kept in BUFFER's `intellij-server-test--seen'."
  (with-current-buffer buffer
    (let ((deadline (+ (float-time) 20)) found)
      (while (and (not found) (< (float-time) deadline))
        (goto-char (point-min))
        (while (re-search-forward "Content-Length: \\([0-9]+\\)\r\n\r\n" nil t)
          (let ((end (+ (point) (string-to-number (match-string 1)))))
            (when (<= end (point-max))
              (let ((message (json-parse-string (buffer-substring (point) end)
                                                :object-type 'plist :null-object nil)))
                (push message intellij-server-test--seen)
                (delete-region (match-beginning 0) end)
                (when (equal (plist-get message :id) id) (setq found message))))))
        (unless found (accept-process-output nil 0.1)))
      found)))

(defvar-local intellij-server-test--seen nil)

(ert-deftest intellij-server-proxy-against-fake-server ()
  (skip-unless (and (intellij-server-test--jbr "javac") (executable-find "python3")))
  (intellij-server-test-with-directory dir
    (let* ((intellij-server-directory dir)
           (server-dir (expand-file-name "server/" dir))
           (project (expand-file-name "proj/" dir))
           (jdk (expand-file-name "jdk" dir))
           (process-environment (cons (concat "JAVA_HOME=" jdk) process-environment))
           (buffer (generate-new-buffer " *proxy*"))
           process)
      (intellij-server-test-touch dir "proj/pom.xml" "jdk/release")
      (make-directory (expand-file-name "bin" server-dir) t)
      (with-temp-file (expand-file-name "bin/intellij-server" server-dir)
        (insert intellij-server-test-fake-server))
      (set-file-modes (expand-file-name "bin/intellij-server" server-dir) #o755)
      (cl-letf* ((java (intellij-server-test--jbr "java"))
                 (javac (intellij-server-test--jbr "javac"))
                 ((symbol-function 'intellij-server--jbr)
                  (lambda (program) (if (equal program "javac") javac java))))
        (setq process
              (make-process
               :name "proxy" :buffer buffer :connection-type 'pipe :coding 'binary
               :noquery t :stderr (get-buffer-create " *proxy stderr*")
               :command (list (intellij-server--jbr "java")
                              "-cp" (intellij-server-proxy-classes) "IntellijServerProxy"
                              "--server" server-dir
                              "--data" (expand-file-name "data" dir)))))
      (unwind-protect
          (progn
            (intellij-server-test--send
             process `(:jsonrpc "2.0" :id 1 :method "initialize"
                       :params (:rootUri ,(concat "file://" (directory-file-name project))
                                :capabilities ,(make-hash-table)
                                :initializationOptions
                                (:intellijExtensions t
                                 :settings (:jetbrains.java.hints.types.local\ variable :false)))))
            (should (intellij-server-test--receive buffer 1))
            ;; The server's settings request is answered by the proxy.
            (let (state)
              (cl-loop for id from 2 to 30
                       do (intellij-server-test--send
                           process `(:jsonrpc "2.0" :id ,id :method "test/state"))
                       (setq state (plist-get (intellij-server-test--receive buffer id) :result))
                       until (plist-get state :config)
                       do (sleep-for 0.1))
              (let ((hints (aref (plist-get state :config) 0))
                    (init (plist-get state :init)))
                (should (eq (plist-get hints :settings.method\ parameter) t))
                (should (eq (plist-get hints :types.local\ variable) :false))
                (should-not (plist-member init :settings))
                (should (eq (plist-get init :intellijExtensions) t))
                (let ((pinned (aref (plist-get init :projects) 0)))
                  (should (equal (plist-get pinned :type) "maven"))
                  (should (equal (plist-get pinned :java-home) jdk)))))
            (with-current-buffer buffer
              (should-not (cl-find "workspace/configuration" intellij-server-test--seen
                                   :key (lambda (m) (plist-get m :method)) :test #'equal)))
            ;; A library source becomes a file, and back.
            (intellij-server-test--send
             process '(:jsonrpc "2.0" :id 100 :method "textDocument/definition"
                       :params (:textDocument (:uri "file:///x/A.java")
                                :position (:line 0 :character 0))))
            (let* ((location (aref (plist-get (intellij-server-test--receive buffer 100) :result) 0))
                   (uri (plist-get location :uri))
                   (file (url-unhex-string (string-remove-prefix "file://" uri))))
              (should (string-suffix-p "/lib-sources.jar/org/A.java" file))
              (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                             "class A {}\n"))
              (should (equal (intellij-server-source-root file) project))
              (intellij-server-test--send
               process `(:jsonrpc "2.0" :method "textDocument/didOpen"
                         :params (:textDocument (:uri ,uri :languageId "java" :version 1
                                                 :text "class A {}\n"))))
              (intellij-server-test--send process '(:jsonrpc "2.0" :id 101 :method "test/state"))
              (should (equal (plist-get (plist-get (intellij-server-test--receive buffer 101) :result)
                                        :didOpen)
                             "jar:///m2/lib-sources.jar!/org/A.java"))))
        (when (process-live-p process) (delete-process process))
        (kill-buffer buffer)))))

;;;; Completion

(ert-deftest intellij-server-eglot-completion-runs-apply-command ()
  (let* ((command '(:title "" :command "jetbrains.kotlin.completion.apply" :arguments [1]))
         (proxy (propertize "App" 'eglot--lsp-item (list :label "App" :command command)))
         exited executed)
    (cl-letf (((symbol-function 'intellij-server-eglot--current) (lambda () 'server))
              ((symbol-function 'eglot-execute)
               (lambda (server action) (setq executed (list server action)))))
      (let* ((capf (intellij-server-eglot--completion
                    (list 1 3 (lambda (&rest _) (list proxy))
                          :exit-function (lambda (p s) (setq exited (list p s))))))
             (exit (plist-get (nthcdr 3 capf) :exit-function)))
        (funcall exit proxy 'finished)
        (should (equal exited (list proxy 'finished)))
        (should (eq (car executed) 'server))
        (should (equal (plist-get (cadr executed) :command) "jetbrains.kotlin.completion.apply"))
        ;; Eglot may strip :title from what it executes, never from the item.
        (should (plist-member command :title))))))

(ert-deftest intellij-server-eglot-completion-leaves-other-items ()
  (let ((proxy (propertize "sout" 'eglot--lsp-item
                           (list :label "sout" :command '(:command "editor.action.triggerSuggest"))))
        executed)
    (cl-letf (((symbol-function 'intellij-server-eglot--current) (lambda () 'server))
              ((symbol-function 'eglot-execute) (lambda (&rest _) (setq executed t))))
      (let ((capf (intellij-server-eglot--completion
                   (list 1 3 (lambda (&rest _) nil) :exit-function #'ignore))))
        (funcall (plist-get (nthcdr 3 capf) :exit-function) proxy 'finished)
        (should-not executed)))
    ;; Other servers' completion is left as it is.
    (cl-letf (((symbol-function 'intellij-server-eglot--current) #'ignore))
      (let ((capf (list 1 3 #'ignore :exit-function #'ignore)))
        (should (eq (intellij-server-eglot--completion capf) capf))))))

;;;; The server's questions

(ert-deftest intellij-server-import-log-appends ()
  (let ((intellij-server-build-log-display nil))
    (when (get-buffer "*intellij-server build*") (kill-buffer "*intellij-server build*"))
    (intellij-server-import-log '(:started t :tool "Maven"))
    (intellij-server-import-log '(:message "Downloading junit"))
    (intellij-server-import-log '(:succeeded t :tool "Maven"))
    (with-current-buffer "*intellij-server build*"
      (should (string-match-p "── Maven started ──\nDownloading junit\n" (buffer-string))))))

(ert-deftest intellij-server-show-conflicts-answers ()
  (cl-letf (((symbol-function 'yes-or-no-p) #'always)
            ((symbol-function 'display-buffer) #'ignore))
    (should (equal (intellij-server-show-conflicts
                    '(:title "Inline method" :continueLabel "Continue"
                      :conflicts [(:messages ["Field x is private"]
                                   :location (:uri "file:///a/B.java"
                                              :range (:start (:line 4 :character 2))))]))
                   '(:decision "continue")))
    (with-current-buffer "*intellij-server conflicts*"
      (should (string-match-p "^/a/B.java:5:3: Field x is private$" (buffer-string))))))

;;; intellij-server-tests.el ends here
