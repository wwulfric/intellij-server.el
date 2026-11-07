EMACS ?= emacs
DEPS ?= ..
BRIDGE_LOAD_PATH = -L $(DEPS)/lsp-bridge -L $(DEPS)/lsp-bridge/acm \
	-L $(DEPS)/markdown-mode -L $(DEPS)/yasnippet -L $(DEPS)/posframe

.PHONY: test test-core test-lsp-bridge
test: test-core test-lsp-bridge

test-core:
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . \
	  -l test/intellij-server-tests.el -f ert-run-tests-batch-and-exit

test-lsp-bridge:
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . $(BRIDGE_LOAD_PATH) \
	  -l test/intellij-server-lsp-bridge-tests.el -f ert-run-tests-batch-and-exit
