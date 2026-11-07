;;; intellij-server-lsp-bridge-tests.el --- Adapter compatibility -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'intellij-server-lsp-bridge)
(intellij-server-lsp-bridge-disable)

(defconst intellij-server-test--advice
  '((lsp-bridge--get-single-lang-server-func . intellij-server-lsp-bridge--single-server)
    (lsp-bridge--get-language-id-func . intellij-server-lsp-bridge--language-id)
    (lsp-bridge--get-project-path-func . intellij-server-lsp-bridge--project-path)))

(defun intellij-server-test--rejected-cleanly ()
  "Check that rejection leaves advice and registration untouched."
  (let ((lsp-bridge-single-lang-server-mode-list nil)
        (lsp-bridge-default-mode-hooks nil))
    (let ((error (should-error (intellij-server-lsp-bridge-enable) :type 'user-error)))
      (should (string-match-p "wwulfric/lsp-bridge" (error-message-string error))))
    (should-not lsp-bridge-single-lang-server-mode-list)
    (should-not lsp-bridge-default-mode-hooks)
    (dolist (entry intellij-server-test--advice)
      (should-not (advice-member-p (cdr entry) (car entry))))))

(ert-deftest intellij-server-bridge-rejects-missing-capabilities ()
  (dolist (feature lsp-bridge-server-config-features)
    (let ((lsp-bridge-server-config-features
           (remq feature (copy-sequence lsp-bridge-server-config-features))))
      (intellij-server-test--rejected-cleanly))))

(ert-deftest intellij-server-bridge-rejects-unadvertised-contract ()
  (cl-progv '(lsp-bridge-server-config-features) nil
    (intellij-server-test--rejected-cleanly)))

(ert-deftest intellij-server-bridge-rejects-changed-entry-points ()
  (dolist (function '(lsp-bridge--get-single-lang-server-func
                      lsp-bridge--get-language-id-func
                      lsp-bridge--get-project-path-func lsp-bridge-execute-command))
    (dolist (replacement (list nil (lambda () nil)))
      (cl-letf (((symbol-function function) replacement))
        (intellij-server-test--rejected-cleanly)))))

(ert-deftest intellij-server-bridge-enables-and-disables-idempotently ()
  (let ((lsp-bridge-single-lang-server-mode-list nil)
        (lsp-bridge-default-mode-hooks nil))
    (unwind-protect
        (progn
          (intellij-server-lsp-bridge-enable)
          (intellij-server-lsp-bridge-enable)
          (dolist (entry intellij-server-test--advice)
            (let ((count 0))
              (advice-mapc (lambda (function _props)
                            (when (eq function (cdr entry)) (cl-incf count)))
                          (car entry))
              (should (= count 1))))
          (should (= (cl-count 'kotlin-ts-mode-hook lsp-bridge-default-mode-hooks) 1)))
      (intellij-server-lsp-bridge-disable))
    (dolist (entry intellij-server-test--advice)
      (should-not (advice-member-p (cdr entry) (car entry))))))

(ert-deftest intellij-server-bridge-preserves-other-language-routing ()
  (cl-letf (((symbol-function 'intellij-server-installed-p) (lambda () t))
            ((symbol-function 'intellij-server-lsp-bridge-config)
             (lambda (root file) (list 'intellij root file))))
    (should (equal (intellij-server-lsp-bridge--single-server #'list "/p/" "/p/a.kt")
                   '(intellij "/p/" "/p/a.kt")))
    (should (equal (intellij-server-lsp-bridge--single-server #'list "/p/" "/p/a.py")
                   '("/p/" "/p/a.py")))))
