TAG = $(shell date +%Y.%m.%d)-$(shell git status --porcelain | grep -q . && echo dirty || git rev-parse --short HEAD)

tag:
	git tag $(TAG)
	git push origin $(TAG)
	@echo "pushed $(TAG) — CI builds the skill and attaches it to the release"
