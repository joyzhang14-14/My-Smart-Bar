.PHONY: app help

# 让 `make app 1.1.0` 这种语法能用（把后面的版本号当成参数而不是 target）
ifeq (app,$(firstword $(MAKECMDGOALS)))
  RELEASE_VERSION := $(wordlist 2,2,$(MAKECMDGOALS))
  $(eval $(RELEASE_VERSION):;@:)
endif

help:
	@echo "Usage:"
	@echo "  make app X.Y.Z   # build, sign, upload release vX.Y.Z to GitHub"
	@echo ""
	@echo "Example:"
	@echo "  make app 1.1.0"

app:
	@if [ -z "$(RELEASE_VERSION)" ]; then \
	  echo "❌ Usage: make app X.Y.Z (e.g. make app 1.1.0)"; \
	  exit 1; \
	fi
	@./scripts/release.sh $(RELEASE_VERSION)
