# packages.mk
#
# packages.mk is responsible for compiling packages.yml to packages.lock
# by expanding its packages using all defaults and templates.
# It also generates the layered Dockerfiles for each package.

# Include config.mk relative to this file (this allows us to invoke this file
# from different directories safely.
include $(shell dirname $(lastword $(MAKEFILE_LIST)))/config.mk

# Disable built-in rules.
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

SHELL := /usr/bin/env bash -euo pipefail -c

THIS_FILE := $(lastword $(MAKEFILE_LIST))

# SPEC is the human-managed description of which packages we are able to build.
SPEC := packages.yml
# LOCK is the generated fully-expanded rendition of SPEC, for use in generating CI
# pipelines and other things.
LOCK := packages.lock

# Temporary files.
TEMPLATE_DIR := .tmp/templates
LAYER_TEMPLATE_DIR := .tmp/layer-templates
DEFAULTS_DIR := .tmp/defaults
RENDERED_DIR := .tmp/rendered
PACKAGES_DIR := .tmp/packages
PACKAGES_WITH_CHECKSUMS_DIR := .tmp/packages-with-checksums
COMMANDS_DIR := .tmp/commands
DOCKERFILES_DIR := .tmp/dockerfiles
DEFAULTS_WITH_ENV := .tmp/defaults-with-env.json
LIST := .tmp/list.yml

# Count the packages we intend to list.
PKG_COUNT := $(shell yq '.packages | length' < $(SPEC))
# Try to speed things up by running all pipelines in parallel.
MAKEFLAGS += -j$(PKG_COUNT)

# Ensure the temp directories exist.
$(shell mkdir -p \
	$(TEMPLATE_DIR) \
	$(LAYER_TEMPLATE_DIR) \
	$(DEFAULTS_DIR) \
	$(RENDERED_DIR) \
	$(PACKAGES_DIR) \
	$(PACKAGES_WITH_CHECKSUMS_DIR) \
	$(COMMANDS_DIR) \
	$(DOCKERFILES_DIR) \
)

# PKG_INDEXES is just the numbers 1..PKG_COUNT, we use this to generate filenames
# for the intermediate files DEFAULTS, RENDERED, PACKAGES and COMMANDS.
PKG_INDEXES := $(shell seq $(PKG_COUNT))
DEFAULTS := $(addprefix $(DEFAULTS_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
RENDERED := $(addprefix $(RENDERED_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
PACKAGES := $(addprefix $(PACKAGES_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
PACKAGES_WITH_CHECKSUMS := $(addprefix $(PACKAGES_WITH_CHECKSUMS_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
COMMANDS := $(addprefix $(COMMANDS_DIR)/,$(addsuffix .sh,$(PKG_INDEXES)))

TEMPLATE_NAMES := $(shell yq -r '.templates | keys[]' < $(SPEC))
TEMPLATES := $(addprefix $(TEMPLATE_DIR)/,$(TEMPLATE_NAMES))

LAYER_NAMES := $(shell yq -r '.layers[] | .name' < $(SPEC))
LAYER_TEMPLATES := $(addprefix $(LAYER_TEMPLATE_DIR)/,$(LAYER_NAMES))

# DOCKERFILES is actually a directory for each package, containing a Dockerfile
# for each layer in that package's configuration.
DOCKERFILES := $(addprefix $(DOCKERFILES_DIR)/,$(PKG_INDEXES))

## PHONY targets for human use.

# list generates the fully expanded package list, this is usually
# what you want.
list: $(LIST)
	@cat $<

# lock updates the lock file with the fully expanded list.
lock: $(LOCK)
	@echo "$< updated."

# commands builds a list of build commands, one for each package.
commands: $(COMMANDS)
	@cat $^ > .tmp/all-commands.sh
	@echo "see .tmp/all-commands.sh"

dockerfiles: $(DOCKERFILES)
	@echo Dockerfiles updated.

# Other phony targets below are for debugging purposes, allowing you
# to run just part of the pipeline.
packages: $(PACKAGES)
	@cat $^

rendered: $(RENDERED)
	@cat $^
	
defaults-with-env: $(DEFAULTS_WITH_ENV)
	@cat $<

defaults: $(DEFAULTS)
	@cat $^

templates: $(TEMPLATES)
	@echo Templates updated: $^

layer-templates: $(LAYER_TEMPLATES)
	@echo Layer templates update $^

.PHONY: list lock commands packages rendered defaults templates

## END PHONY targets.

# TEMPLATES writes out a file for each template in the spec, so we can refer to them
# individually later.
$(TEMPLATE_DIR)/%: $(SPEC) $(THIS_FILE)
	@echo -n '{{$$d := (datasource "vars")}}{{with $$d}}' > $@; \
		yq -r ".templates.$*" $< >> $@; \
		echo "{{end}}" >> $@

$(LAYER_TEMPLATE_DIR)/%: $(SPEC) $(THIS_FILE)
	@echo -n '{{$$d := (datasource "vars")}}{{with $$d}}' > $@; \
		yq -r '.layers[] | select(.name == "$*") | .dockerfile' $< >> $@; \
		echo "{{end}}" >> $@

.PHONY: $(DEFAULTS_WITH_ENV)
$(DEFAULTS_WITH_ENV): $(SPEC) $(THIS_FILE)
	@rm -f $@.withenv
	@yq -r '.defaults | keys[]' < $< | while read -r NAME; do \
		if [ -n "$${!NAME+x}" ]; then \
			echo "$$NAME: $${!NAME}" >> $@.withenv; \
		else \
			echo "$$NAME: \"$$(yq -r ".defaults.$$NAME" < $<)"\" >> $@.withenv; \
		fi; \
	done; \
	yq . < $@.withenv > $@

# DEFAULTS are generated by this rule, they contain just the packages listed in
# SPEC plus default values to fill in any gaps. These are used as the data source
# to the templates above for rendering.
$(DEFAULTS_DIR)/%.json: $(DEFAULTS_WITH_ENV) $(SPEC)
	@yq -c '[ .defaults as $$defaults | .packages[$*-1] | $$defaults + . ][]' < $(SPEC) > $@
	@yq -s '[ .[0] as $$defaults | .[1].packages[$*-1] | $$defaults + .][]' $(DEFAULTS_WITH_ENV) $(SPEC) > $@

# RENDERED files are generated by this rule. These files contain just the
# rendered template values for each of the DEFAULTS files we created above.
# We manually build up a YAML map in the file, then dump it out to JSON for
# use by the PACKAGES targets.
$(RENDERED_DIR)/%.json: $(DEFAULTS_DIR)/%.json $(TEMPLATES)
	@OUT=$@.yml; \
	find $(TEMPLATE_DIR) -mindepth 1 -maxdepth 1 | while read -r T; do \
	  TNAME=$$(basename $$T); \
	  echo -n "$$TNAME: " >> $$OUT; \
	  gomplate -f $$T -d vars=$< | xargs >> $$OUT; \
	done; \
	yq . < $$OUT > $@; rm -f $$OUT

# PACKAGES files are created by this rule. They contain a merge of DEFAULTS plus
# rendered template files.
$(PACKAGES_DIR)/%.json: $(DEFAULTS_DIR)/%.json $(RENDERED_DIR)/%.json
	@# Combine the defaults with rendered templates.
	@jq -s '.[0] + .[1]' $^ | yq -y . > $@

# DOCKERFILES are generated by this rule. Each dockerfile is addressed by its content,
# and a copy of each is placed in layers.lock. layers.lock then contains one Dockerfile
# for each variant required by any package.
$(DOCKERFILES_DIR)/%: $(PACKAGES_DIR)/%.json $(LAYER_TEMPLATES)
	@rm -rf $@; mkdir -p $@
	@export BASE_LAYER_CHECKSUM="none"; \
	export BASE_LAYER_ID=""; \
	for NAME in $(LAYER_NAMES); do \
		DF=$@/$$NAME.Dockerfile; \
		T=$(LAYER_TEMPLATE_DIR)/$$NAME; \
		gomplate -f $$T -d vars=$< > $$DF; \
		LAYER_CHECKSUM=$$(sha256sum < $$DF | cut -d' ' -f1); \
		LAYER_ID=$${NAME}_$${LAYER_CHECKSUM}; \
		echo "Comment: Write this checksum to a file for later reference." > /dev/null; \
		echo "$$LAYER_CHECKSUM" > $$DF.checksum; \
		echo "Comment: Copy this layer out to layers.lock for reference from packages." > /dev/null; \
		mkdir -p $$(dirname layers.lock/$$LAYER_ID); \
		cp $$DF layers.lock/$$LAYER_ID.Dockerfile; \
		echo "Comment: write the makefile fragment for this layer." > /dev/null; \
		echo "TODO: Factor this out, it's a hangover from earlier implementation." > /dev/null; \
		MKFILE="layers.lock/$$LAYER_ID.mk"; \
		SOURCE_INCLUDE="$$(yq -r ".layers[] | select(.name==\"$$NAME\") | .[\"source-include\"]" < $(SPEC))"; \
		SOURCE_EXCLUDE="$$(yq -r ".layers[] | select(.name==\"$$NAME\") | .[\"source-exclude\"]" < $(SPEC))"; \
		rm -f $$MKFILE; \
		echo "LAYER_$${LAYER_ID}_ID             := $${LAYER_ID}" >> $$MKFILE; \
		echo "LAYER_$${LAYER_ID}_BASE_LAYER     := $${BASE_LAYER_ID}" >> $$MKFILE; \
		echo "LAYER_$${LAYER_ID}_SOURCE_INCLUDE := $${SOURCE_INCLUDE}" >> $$MKFILE; \
		echo "LAYER_$${LAYER_ID}_SOURCE_EXCLUDE := $${SOURCE_EXCLUDE}" >> $$MKFILE; \
		echo '$$(eval $$(call LAYER,$$(LAYER_'$${LAYER_ID}'_ID),$$(LAYER_'$${LAYER_ID}'_BASE_LAYER),$$(LAYER_'$${LAYER_ID}'_SOURCE_INCLUDE),$$(LAYER_'$${LAYER_ID}'_SOURCE_EXCLUDE)))' >> $$MKFILE; \
		echo "Comment: Set BASE_LAYER_CHECKSUM and ID ready for the next layer." > /dev/null; \
		BASE_LAYER_CHECKSUM=$$LAYER_CHECKSUM; \
		BASE_LAYER_ID=$$LAYER_ID; \
	done; \
	echo "BUILD_LAYER_IMAGE = \$$($${LAYER_ID}_IMAGE)" >> $$MKFILE; \
	echo "BUILD_LAYER_IMAGE_NAME = \$$($${LAYER_ID}_IMAGE_NAME)" >> $$MKFILE; \
	# ^ for the last layer (the one that builds packages), specify BUILD_LAYER_IMAGE to point to it.

$(PACKAGES_WITH_CHECKSUMS_DIR)/%.json: $(PACKAGES_DIR)/%.json $(DOCKERFILES_DIR)/%
	@# Add references to the layer Dockerfiles.
	@# Add the package spec ID.
	@cp $< $@
	@echo "CIRCLECI_CACHE_KEY_SEGMENTS:" >> $@
	@for NAME in $(LAYER_NAMES); do \
		LAYER_CHECKSUM=$$(cat $(DOCKERFILES_DIR)/$*/$$NAME.Dockerfile.checksum); \
		LAYER_ID="$${NAME}-$${LAYER_CHECKSUM}"; \
		LAYER_SEGMENT="$${NAME}-{{checksum $(CACHE_ROOT)/$${LAYER_ID}-cache-key}}"; \
		echo "  - $${LAYER_SEGMENT}" >> $@; \
	done; \
	echo "BUILDER_LAYER_ID: $${NAME}_$$(cat $(DOCKERFILES_DIR)/$*/$$NAME.Dockerfile.checksum)" >> $@
	@echo "PACKAGE_SPEC_ID: $$(sha256sum < $@ | cut -d' ' -f1)" >> $@
	@yq . < $@ | sponge $@

PACKAGE_COMMAND := make -C ../ -f release/build.mk package

# LIST just plonks all the package json files generated above into an array,
# and converts it to YAML.
$(LIST): $(PACKAGES_WITH_CHECKSUMS)
	@jq -s '{ packages: . }' $(PACKAGES_WITH_CHECKSUMS) | yq -y . >$@

$(LOCK): $(LIST)
	@echo "### ***" > $@
	@echo "### WARNING: DO NOT manually EDIT or MERGE this file, it is generated by 'make $@'." >> $@
	@echo "### INSTEAD: Edit or merge the source in this directory then run 'make $@'." >> $@
	@echo "### ***" >> $@
	@cat $< >> $@

# COMMANDS files are created by this rule. They are one-line shell scripts that can
# be invoked from the release/ directory to produce a certain package.
$(COMMANDS_DIR)/%.sh: $(PACKAGES_WITH_CHECKSUMS_DIR)/%.json $(LOCK)
	@{ echo "# Build package: $$(jq -r '.PACKAGE_NAME' < $<)"; } > $@ 
	@{ jq "to_entries | .[] | select((.value | type)!=\"array\" and (.value | type)!=\"object\") | \"\(.key)='\(.value)'\"" \
		< $<; echo "$(PACKAGE_COMMAND)"; } | xargs >> $@

