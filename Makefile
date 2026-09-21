VERSION ?= 0.1.0
SKILL_TAG ?= $(shell date -u +%Y-%m-%d)-1

.PHONY: build tag-vibed tag-skill

build:
	cd vibed && cargo build --release

# Release vibed binaries: pushes the tag that triggers .github/workflows/vibed-release.yml
tag-vibed:
	git tag "vibed-release/$(VERSION)"
	git push origin "vibed-release/$(VERSION)"

# Release the skill kit: pushes the tag that triggers .github/workflows/skill-release.yml
# (stamps the version footer into SKILL.md at release time)
tag-skill:
	git tag "$(SKILL_TAG)"
	git push origin "$(SKILL_TAG)"
