;;; intellij-server-eglot.el --- The IntelliJ language server in eglot -*- lexical-binding: t; -*-

;;; Commentary:
;; Makes eglot the IDE the IntelliJ server expects:
;;
;; - flat, dotted settings for `workspace/configuration', without which
;;   the server turns every inlay hint off;
;; - completion items whose insertion is the server's own command, with
;;   their imports, parentheses and caret placement;
;; - the `intellij/*' questions refactorings ask mid-way, its build log and
;;   its license state;
;; - library and JDK sources (`jar:' and `jrt:' URIs) as read-only buffers
;;   the server decompiles, which navigation keeps working in.
;;
;;   (require 'intellij-server-eglot)
;;   (add-hook 'java-ts-mode-hook #'eglot-ensure)

;;; Code:

(require 'eglot)
(require 'intellij-server)

(defclass eglot-intellij-server (eglot-lsp-server) ()
  :documentation "JetBrains' IntelliJ language server.")

(defcustom intellij-server-eglot-modes
  '(java-mode java-ts-mode kotlin-mode kotlin-ts-mode)
  "Major modes that eglot serves with the IntelliJ server."
  :type '(repeat symbol)
  :group 'intellij-server)

(defun intellij-server-eglot-contact (&rest _)
  "Return eglot's contact for the IntelliJ server."
  (cons 'eglot-intellij-server (intellij-server-command)))

(defun intellij-server-eglot--root (server)
  (expand-file-name (project-root (eglot--project server))))

(cl-defmethod eglot-initialization-options ((server eglot-intellij-server))
  (intellij-server-initialization-options (intellij-server-eglot--root server)))

(cl-defmethod eglot-client-capabilities ((_server eglot-intellij-server))
  ;; The license state is ours to show, as the VS Code client declares.
  (plist-put (cl-call-next-method) :experimental '(:licensingUi t)))

(cl-defmethod eglot-handle-request
  ((server eglot-intellij-server) (_method (eql workspace/configuration)) &key items)
  "Answer from flat dotted keys; eglot would look for nested sections."
  (let ((settings (intellij-server--project-local (intellij-server-eglot--root server)
                                                  'intellij-server-settings)))
    (apply #'vector
           (mapcar (lambda (item)
                     (intellij-server-configuration (plist-get item :section) settings))
                   items))))

;;;; Completion

(defun intellij-server-eglot--command-p (command)
  "Return non-nil if COMMAND inserts a completion server-side.
Such items come with an empty edit; the server's apply command brings
the text, imports and caret through `workspace/applyEdit' and
`window/showDocument'."
  (and command
       (string-match-p "\\`jetbrains\\..+\\.completion\\.apply\\'"
                       (or (plist-get command :command) ""))))

(defun intellij-server-eglot--current ()
  "Return the current buffer's server if it is the IntelliJ server."
  (let ((server (eglot-current-server)))
    (and (cl-typep server 'eglot-intellij-server) server)))

(defun intellij-server-eglot--completion (capf)
  "Make CAPF, eglot's completion, run the server's apply command.
LSP has the client run an item's command after its edit, which eglot
leaves out."
  (pcase capf
    (`(,beg ,end ,table . ,props)
     (if-let* ((server (intellij-server-eglot--current))
               (exit (plist-get props :exit-function)))
         `(,beg ,end ,table
                ,@(plist-put
                   (copy-sequence props) :exit-function
                   (lambda (proxy status)
                     (let* ((item (or (get-text-property 0 'eglot--lsp-item proxy)
                                      ;; Chosen from *Completions*, PROXY has no
                                      ;; properties; find it among the candidates.
                                      (get-text-property
                                       0 'eglot--lsp-item
                                       (or (cl-find proxy (all-completions "" table)
                                                    :test #'string=)
                                           ""))))
                            (command (plist-get item :command)))
                       (funcall exit proxy status)
                       (when (and (memq status '(finished exact))
                                  (intellij-server-eglot--command-p command))
                         ;; Eglot strips :title from the command it executes.
                         (eglot-execute server (copy-sequence command)))))))
       capf))
    (_ capf)))

(advice-add 'eglot-completion-at-point :filter-return #'intellij-server-eglot--completion)

(cl-defmethod eglot-handle-request
  ((_server eglot-intellij-server) (_method (eql window/showDocument))
   &key uri external selection &allow-other-keys)
  "Place the caret after a completion right away, in the window typed in.
Eglot would wait for the command to end, and might show another window."
  (let ((buffer (window-buffer (selected-window))))
    (if (and selection (not (eq external t))
             (buffer-local-value 'buffer-file-name buffer)
             (equal (eglot-uri-to-path uri) (buffer-local-value 'buffer-file-name buffer)))
        (with-current-buffer buffer
          (goto-char (car (eglot-range-region selection)))
          (set-window-point (selected-window) (point))
          '(:success t))
      (cl-call-next-method))))

;;;; The server's own messages

(defun intellij-server-eglot--later (server function)
  "Run FUNCTION in the buffer SERVER means once the current message is done.
That is the selected window's when SERVER manages it, else the most
recently used one it manages: the message names no file.  The server
sends its follow-ups after the edit they belong to."
  (let* ((managed (eglot--managed-buffers server))
         (buffer (cl-find-if (lambda (b) (memq b managed))
                             (cons (window-buffer (selected-window)) (buffer-list)))))
    (run-at-time 0 nil (lambda ()
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer (funcall function)))))))

(defvar intellij-server-eglot-editor-commands
  '(("editor.action.rename" . eglot-rename)
    ("editor.action.triggerParameterHints" . eldoc)
    ("editor.action.triggerSuggest" . completion-at-point))
  "Commands to run for the VS Code command ids of `intellij/runEditorCommand'.")

(cl-defmethod eglot-handle-notification
  ((server eglot-intellij-server) (_method (eql intellij/runEditorCommand))
   &key command &allow-other-keys)
  "Follow up an edit the way the server asks: rename what it just introduced,
show parameter hints, complete."
  (if-let* ((function (cdr (assoc command intellij-server-eglot-editor-commands))))
      (intellij-server-eglot--later server (lambda () (call-interactively function)))
    (eglot--message "No equivalent for the server's editor command %s" command)))

(cl-defmethod eglot-handle-notification
  ((server eglot-intellij-server) (_method (eql intellij/chooseAction))
   &key title entries &allow-other-keys)
  "Let the user choose how a refactoring continues."
  (intellij-server-eglot--later
   server
   (lambda ()
     (intellij-server-choose-action
      title (append entries nil)
      (lambda (command) (eglot-execute server (copy-sequence command)))))))

(cl-defmethod eglot-handle-request
  ((_server eglot-intellij-server) (_method (eql intellij/showConflicts)) &rest params)
  "Ask whether a refactoring goes ahead despite its conflicts."
  (intellij-server-show-conflicts params))

(cl-defmethod eglot-handle-notification
  ((_server eglot-intellij-server) (_method (eql intellij/copyToClipboard)) &rest params)
  (intellij-server-copy-to-clipboard params))

(cl-defmethod eglot-handle-notification
  ((_server eglot-intellij-server) (_method (eql intellij/workspaceImportStatus)) &rest params)
  (intellij-server-import-status params))

(cl-defmethod eglot-handle-notification
  ((_server eglot-intellij-server) (_method (eql intellij/workspaceImportState)) &rest _)
  "Import progress, which `$/progress' already reports.")

(cl-defmethod eglot-handle-notification
  ((_server eglot-intellij-server) (_method (eql intellij/importLog)) &rest params)
  (intellij-server-import-log params))

(cl-defmethod eglot-handle-notification
  ((_server eglot-intellij-server) (_method (eql jetbrains/licensing/state)) &rest params)
  (intellij-server-license-state params))

;;;; Library sources

(defun intellij-server-eglot--servers ()
  "Return the running IntelliJ servers, the current buffer's first."
  (let ((current (ignore-errors (eglot-current-server)))
        servers)
    (maphash (lambda (_ list)
               (dolist (server list)
                 (when (cl-typep server 'eglot-intellij-server) (push server servers))))
             eglot--servers-by-project)
    (if (memq current servers) (cons current (delq current servers)) servers)))

(defun intellij-server-eglot--decompile (uri)
  "Return the source of library URI and the server that read it.
A server only reads the archives of its own projects, so each is asked."
  (or (cl-loop for server in (intellij-server-eglot--servers)
               for result = (ignore-errors
                              (jsonrpc-request server :workspace/executeCommand
                                               `(:command "decompile" :arguments [,uri])
                                               :timeout 15))
               for text = (if (stringp result) result
                            (or (plist-get result :code) (plist-get result :text)))
               when text return (cons text server))
      (error "No IntelliJ server could read %s (indexing may not be done)" uri)))

(defvar-local intellij-server-eglot--source-root nil
  "Project root of the server that decompiled this library source.")
(put 'intellij-server-eglot--source-root 'permanent-local t)

(defun intellij-server-eglot--file-handler (operation &rest args)
  "Serve `jar:' and `jrt:' names as read-only files the server decompiles.
Their buffers join the server of the project the source belongs to."
  (pcase operation
    ((or 'expand-file-name 'file-truename 'substitute-in-file-name)
     (car args))
    ((or 'file-exists-p 'file-readable-p) t)
    ((or 'file-writable-p 'file-directory-p 'file-remote-p 'file-symlink-p
         'file-locked-p 'vc-registered 'file-name-case-insensitive-p 'file-executable-p
         'file-newer-than-file-p 'make-auto-save-file-name 'unhandled-file-name-directory)
     nil)
    ((or 'lock-file 'unlock-file 'set-visited-file-modtime) nil)
    ('verify-visited-file-modtime t)
    ('file-attributes nil)
    ('insert-file-contents
     (pcase-let* ((`(,file ,visit . ,_) args)
                  (`(,text . ,server) (intellij-server-eglot--decompile file)))
       (save-excursion (insert text))
       (when visit
         (setq buffer-file-name file
               intellij-server-eglot--source-root
               (file-name-as-directory (intellij-server-eglot--root server)))
         (set-buffer-modified-p nil))
       (list file (length text))))
    (_ (let ((inhibit-file-name-handlers
              (cons #'intellij-server-eglot--file-handler
                    (and (eq inhibit-file-name-operation operation)
                         inhibit-file-name-handlers)))
             (inhibit-file-name-operation operation))
         (apply operation args)))))

(add-to-list 'file-name-handler-alist
             '("\\`\\(jar\\|jrt\\):" . intellij-server-eglot--file-handler))

(defun intellij-server-eglot--enter-source-project ()
  "Give a library source the directory of the project that reads it.
Visiting sets it to the archive's; this runs before eglot looks up the
project's server for the new major mode."
  (when intellij-server-eglot--source-root
    (setq default-directory intellij-server-eglot--source-root)))

(add-hook 'after-change-major-mode-hook #'intellij-server-eglot--enter-source-project -50)

;;;; Registration

(defun intellij-server-eglot-enable ()
  "Serve `intellij-server-eglot-modes' with the IntelliJ server."
  (add-to-list 'eglot-server-programs
               (cons intellij-server-eglot-modes #'intellij-server-eglot-contact)))

(intellij-server-eglot-enable)

(provide 'intellij-server-eglot)
;;; intellij-server-eglot.el ends here
