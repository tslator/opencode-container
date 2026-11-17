.PHONY: build build-latest shell clean tag-latest build-builder-tools prune-cache herdr-skill skills skills-bump

ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
USER_UID := $(shell id -u)
USER_GID := $(shell id -g)
VERSION ?=

# Forward host proxy env into make shell and the runtime container; each case is
# derived from whichever of HTTP_PROXY/http_proxy (etc.) the caller exported.
HTTP_PROXY_EFF := $(or $(HTTP_PROXY),$(http_proxy))
HTTPS_PROXY_EFF := $(or $(HTTPS_PROXY),$(https_proxy))
NO_PROXY_EFF := $(or $(NO_PROXY),$(no_proxy))
PROXY_HTTP_RA := $(if $(HTTP_PROXY_EFF),-e 'HTTP_PROXY=$(HTTP_PROXY_EFF)' -e 'http_proxy=$(HTTP_PROXY_EFF)',)
PROXY_HTTPS_RA := $(if $(HTTPS_PROXY_EFF),-e 'HTTPS_PROXY=$(HTTPS_PROXY_EFF)' -e 'https_proxy=$(HTTPS_PROXY_EFF)',)
PROXY_NO_RA := $(if $(NO_PROXY_EFF),-e 'NO_PROXY=$(NO_PROXY_EFF)' -e 'no_proxy=$(NO_PROXY_EFF)',)
PROXY_RUN_ARGS := $(PROXY_HTTP_RA) $(PROXY_HTTPS_RA) $(PROXY_NO_RA)

ifneq ($(findstring @,$(HTTP_PROXY_EFF)),)
$(error HTTP_PROXY must not contain embedded credentials)
endif
ifneq ($(findstring @,$(HTTPS_PROXY_EFF)),)
$(error HTTPS_PROXY must not contain embedded credentials)
endif

# Vendored skills library (private repo; requires `gh auth`). The checkout is
# pinned by vendor/my-skills.sha and copied into the image at /opt/my-skills.
# `make skills-bump` re-pins to upstream HEAD; `make skills` refreshes the
# checkout; build depends on it so the COPY source always exists.
MY_SKILLS_REPO ?= tslator/my-skills
MY_SKILLS_SHA := $(shell cat vendor/my-skills.sha 2>/dev/null)

vendor/my-skills: vendor/my-skills.sha
	@[ -n "$(MY_SKILLS_SHA)" ] || { echo "error: vendor/my-skills.sha is empty"; exit 1; }
	@command -v gh >/dev/null || { echo "error: gh CLI required to clone $(MY_SKILLS_REPO)"; exit 1; }
	@rm -rf vendor/my-skills && mkdir -p vendor
	@gh repo clone $(MY_SKILLS_REPO) vendor/my-skills -- --quiet
	@cd vendor/my-skills && git checkout --quiet $(MY_SKILLS_SHA) && rm -rf .git .[!.]*
	@echo "vendored $(MY_SKILLS_REPO)@$(MY_SKILLS_SHA)"

skills: vendor/my-skills

skills-bump:
	@sha=$$(gh api repos/$(MY_SKILLS_REPO)/commits/HEAD --jq .sha) && \
	echo "$$sha" > vendor/my-skills.sha && echo "pinned $(MY_SKILLS_REPO)@$${sha}"

build: vendor/my-skills
	$(ENGINE) build --build-arg USER_UID=$(USER_UID) --build-arg USER_GID=$(USER_GID) $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),) -t opencode-container$(if $(VERSION),:$(VERSION),) .

build-builder-tools:
	$(ENGINE) build --build-arg USER_UID=$(USER_UID) --build-arg USER_GID=$(USER_GID) $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),) --target builder-tools -t opencode-container:builder-tools .

tag-latest:
ifndef VERSION
	$(error VERSION is required. Usage: make tag-latest VERSION=2.0.9)
endif
	$(ENGINE) tag opencode-container:$(VERSION) opencode-container:latest

# Regenerate the bundled herdr agent skill from the built image's pinned binary.
# Run after bumping HERDR_VERSION, then commit config/skills/herdr/SKILL.md.
herdr-skill:
	@mkdir -p config/skills/herdr
	@$(ENGINE) run --rm --entrypoint herdr opencode-container:latest --skill > config/skills/herdr/SKILL.md
	@echo "regenerated config/skills/herdr/SKILL.md"

build-latest:
	@VERSION=$$(curl -fsSL https://registry.npmjs.org/%40opencode%2Fcli | jq -r '."dist-tags".latest') && \
	echo "Building opencode-container:$$VERSION..." && \
	$(MAKE) build VERSION=$$VERSION && \
	$(MAKE) tag-latest VERSION=$$VERSION

shell: build-builder-tools
	mkdir -p homebase config workspace secrets
	$(ENGINE) run --rm -it --workdir /workspace --read-only \
		--tmpfs /tmp:exec,size=512m,mode=1777 --cap-drop=ALL \
		--security-opt=no-new-privileges --memory=2g --cpus=2 \
		-v $(shell pwd)/homebase:/app:rw,Z \
		-v $(shell pwd)/config:/app/.config/opencode:rw,Z \
		-v $(shell pwd)/workspace:/workspace:rw,Z \
		-v $(shell pwd)/secrets:/run/secrets:ro,Z \
		$(PROXY_RUN_ARGS) \
		--entrypoint /bin/bash \
		opencode-container:builder-tools

clean:
	$(ENGINE) rmi opencode-container || true

prune-cache:
	$(ENGINE) builder prune -f
