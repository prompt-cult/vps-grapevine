SKILL_TAG ?= $(shell date -u +%Y-%m-%d)-1

.PHONY: build tag

build:
	cd vibed && cargo build --release

# Release everything (skill kit + vibed binaries): one tag, one release.
tag:
	git tag "$(SKILL_TAG)"
	git push origin "$(SKILL_TAG)"
