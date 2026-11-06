EMACS ?= emacs

.PHONY: test
test:
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . \
	  -l test/intellij-server-tests.el -f ert-run-tests-batch-and-exit
