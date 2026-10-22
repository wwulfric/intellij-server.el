;;; intellij-server-lsp-bridge.el --- The IntelliJ language server in lsp-bridge -*- lexical-binding: t; -*-

;;; Commentary:
;; Serves Java and Kotlin files with the IntelliJ server through lsp-bridge
;; once it is installed, in place of jdtls and kotlin-language-server.
;; Each project gets a generated server config: the command with its EULA
;; hash and environment, `initializationOptions' and the flat settings,
;; plus the lsp-bridge features the server relies on:
;;
;; - "completionItemCommands": the items whose apply command inserts the
;;   completion, with its imports and caret;
;; - "decompileCommand": library and JDK sources behind `jar:' and `jrt:'
;;   URIs;
;; - "emacsHandlers": the `intellij/*' questions refactorings ask, the
;;   build log and the license state.
;;
;;   (require 'intellij-server-lsp-bridge)

;;; Code:

(require 'json)
(require 'lsp-bridge)
(require 'intellij-server)

(defcustom intellij-server-lsp-bridge-extensions '("java" "kt" "kts")
  "Extensions of the files lsp-bridge serves with the IntelliJ server."
  :type '(repeat string)
  :group 'intellij-server)

(defconst intellij-server-lsp-bridge--handlers
  '(("intellij/runEditorCommand" . intellij-server-lsp-bridge--editor-command)
    ("intellij/chooseAction" . intellij-server-lsp-bridge--choose-action)
    ("intellij/showConflicts" . intellij-server-show-conflicts)
    ("intellij/copyToClipboard" . intellij-server-copy-to-clipboard)
    ("intellij/workspaceImportStatus" . intellij-server-import-status)
    ("intellij/importLog" . intellij-server-import-log)
    ("jetbrains/licensing/state" . intellij-server-license-state))
  "Emacs functions for the server's own messages.")

(defun intellij-server-lsp-bridge-config (project-path _filepath)
  "Write the server's lsp-bridge config for PROJECT-PATH and return its file.
It is written again for every new server, so changed settings apply
after `lsp-bridge-restart-process'."
  (let* ((root (file-name-as-directory
                (expand-file-name (if (file-directory-p project-path) project-path
                                    (file-name-directory project-path)))))
         (file (expand-file-name (format "lsp-bridge/%s/intellij-server.json" (md5 root))
                                 intellij-server-directory))
         (config
          (list :name "intellij-server"
                :languageId "java"
                :command (vconcat (intellij-server-command))
                :settings (intellij-server--object
                           (intellij-server--project-local root 'intellij-server-settings))
                :initializationOptions (intellij-server-initialization-options root)
                ;; The license state is ours to show, as the VS Code client declares.
                :capabilities '(:experimental (:licensingUi t))
                :completionItemCommands ["^jetbrains\\..+\\.completion\\.apply$"]
                :decompileCommand "decompile"
                :emacsHandlers (intellij-server--object
                                (mapcar (lambda (h) (cons (car h) (symbol-name (cdr h))))
                                        intellij-server-lsp-bridge--handlers)))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-encode config)))
    file))

(defun intellij-server-lsp-bridge--serves-p (filename)
  (and (stringp filename)
       (member (file-name-extension filename) intellij-server-lsp-bridge-extensions)
       (intellij-server-installed-p)))

(defun intellij-server-lsp-bridge--single-server (original project-path filename)
  "Choose the IntelliJ server for FILENAME's language, else call ORIGINAL.
Decided by the file, not the current buffer: lsp-bridge asks from
whichever buffer is current when its process gets to it."
  (if (intellij-server-lsp-bridge--serves-p filename)
      (intellij-server-lsp-bridge-config project-path filename)
    (funcall original project-path filename)))

(defun intellij-server-lsp-bridge--language-id (original project-path file-path server-name extension)
  "Tell Kotlin from Java to the one server that reads both."
  (if (equal server-name "intellij-server")
      (if (member extension '("kt" "kts")) "kotlin" "java")
    (funcall original project-path file-path server-name extension)))

;;;; The server's own messages

(defvar acm-backend-lsp-server-names)

(defun intellij-server-lsp-bridge--buffer ()
  "Return the buffer the server's follow-up is for.
That is the selected window's when the server serves it, else the
most recently used buffer it serves: the message names no file."
  (cl-find-if (lambda (buffer)
                (with-current-buffer buffer
                  (and (bound-and-true-p lsp-bridge-mode)
                       (member "intellij-server" acm-backend-lsp-server-names))))
              (cons (window-buffer (selected-window)) (buffer-list))))

(defun intellij-server-lsp-bridge--later (function)
  "Run FUNCTION in the buffer the server means once lsp-bridge is done.
The server sends its follow-ups after the edit they belong to."
  (let ((buffer (intellij-server-lsp-bridge--buffer)))
    (run-at-time 0 nil (lambda ()
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer (funcall function)))))))

(defvar intellij-server-lsp-bridge-editor-commands
  '(("editor.action.rename" . lsp-bridge-rename)
    ("editor.action.triggerParameterHints" . lsp-bridge-signature-help-fetch)
    ("editor.action.triggerSuggest" . lsp-bridge-popup-complete-menu))
  "Commands to run for the VS Code command ids of `intellij/runEditorCommand'.")

(defun intellij-server-lsp-bridge--editor-command (params)
  "Follow up an edit the way PARAMS ask: rename what it just introduced,
show parameter hints, complete."
  (let ((command (plist-get params :command)))
    (if-let* ((function (cdr (assoc command intellij-server-lsp-bridge-editor-commands))))
        (intellij-server-lsp-bridge--later (lambda () (call-interactively function)))
      (message "[intellij-server] No equivalent for the server's editor command %s" command))))

(defun intellij-server-lsp-bridge--choose-action (params)
  "Let the user choose how a refactoring continues, among PARAMS' entries."
  (intellij-server-lsp-bridge--later
   (lambda ()
     (intellij-server-choose-action
      (plist-get params :title) (plist-get params :entries)
      (lambda (command) (lsp-bridge-execute-command "intellij-server" command))))))

;;;; Registration

(defun intellij-server-lsp-bridge-enable ()
  "Serve `intellij-server-lsp-bridge-extensions' with the IntelliJ server."
  (advice-add 'lsp-bridge--get-single-lang-server-func :around
              #'intellij-server-lsp-bridge--single-server)
  (advice-add 'lsp-bridge--get-language-id-func :around
              #'intellij-server-lsp-bridge--language-id)
  ;; lsp-bridge only knows `kotlin-mode'.
  (unless (assq 'kotlin-ts-mode lsp-bridge-single-lang-server-mode-list)
    (add-to-list 'lsp-bridge-single-lang-server-mode-list
                 '(kotlin-ts-mode . "kotlin-language-server") t))
  (add-to-list 'lsp-bridge-default-mode-hooks 'kotlin-ts-mode-hook t))

(defun intellij-server-lsp-bridge-disable ()
  "Return Java and Kotlin files to lsp-bridge's own servers."
  (advice-remove 'lsp-bridge--get-single-lang-server-func
                 #'intellij-server-lsp-bridge--single-server)
  (advice-remove 'lsp-bridge--get-language-id-func
                 #'intellij-server-lsp-bridge--language-id))

(intellij-server-lsp-bridge-enable)

(provide 'intellij-server-lsp-bridge)
;;; intellij-server-lsp-bridge.el ends here
