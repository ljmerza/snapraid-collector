SHELL := /bin/bash
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SYSTEMD_DIR ?= /etc/systemd/system

SHELLCHECK ?= $(shell command -v shellcheck)
SHFMT ?= $(shell command -v shfmt)

SCRIPTS := snapraid_metrics_collector.sh tests/bin/fake_snapraid tests/run.sh

.PHONY: lint lint-shellcheck lint-shfmt test ci install install-systemd uninstall clean

lint: lint-shellcheck lint-shfmt

lint-shellcheck:
	@if [ -n "$(SHELLCHECK)" ]; then \
		$(SHELLCHECK) snapraid_metrics_collector.sh tests/bin/fake_snapraid tests/run.sh; \
	else \
		echo "shellcheck not found, skipping"; \
	fi

lint-shfmt:
	@if [ -n "$(SHFMT)" ]; then \
		tmp="$$(mktemp)"; \
		if ! $(SHFMT) -d $(SCRIPTS) > $$tmp; then \
			cat $$tmp; \
			rm -f $$tmp; \
			exit 1; \
		fi; \
		if [ -s $$tmp ]; then \
			echo "shfmt suggested changes:"; \
			cat $$tmp; \
			rm -f $$tmp; \
			exit 1; \
		fi; \
		rm -f $$tmp; \
	else \
		echo "shfmt not found, skipping"; \
	fi

test:
	./tests/run.sh

ci: lint test

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 snapraid_metrics_collector.sh "$(DESTDIR)$(BINDIR)/snapraid_metrics_collector.sh"

install-systemd:
	install -d "$(DESTDIR)$(SYSTEMD_DIR)"
	install -m 0644 contrib/snapraid-metrics-collector.service "$(DESTDIR)$(SYSTEMD_DIR)/snapraid-metrics-collector.service"

uninstall:
	@if [ -f "$(DESTDIR)$(BINDIR)/snapraid_metrics_collector.sh" ]; then \
		rm -f "$(DESTDIR)$(BINDIR)/snapraid_metrics_collector.sh"; \
	fi
	@if [ -f "$(DESTDIR)$(SYSTEMD_DIR)/snapraid-metrics-collector.service" ]; then \
		rm -f "$(DESTDIR)$(SYSTEMD_DIR)/snapraid-metrics-collector.service"; \
	fi

clean:
	rm -rf tests/tmp
