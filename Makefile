ADDON   := KrrlXPBar
VERSION := $(shell sed -n 's/^## Version: *//p' $(ADDON)/$(ADDON).toc | head -1)
GITREF  := $(shell git rev-parse --short HEAD)
DIST    := dist

DEV_ZIP     := $(DIST)/$(ADDON)-$(VERSION)-$(GITREF).zip
RELEASE_ZIP := $(DIST)/$(ADDON)-$(VERSION).zip

SRC := $(ADDON)/$(ADDON).lua $(ADDON)/$(ADDON).toc

.PHONY: all zip release clean

all: zip

# Dev build, tagged with the current commit so builds from different
# commits don't collide/overwrite each other.
zip: $(DEV_ZIP)

$(DEV_ZIP): $(SRC)
	mkdir -p $(DIST)
	rm -f $(DEV_ZIP)
	zip -r $(DEV_ZIP) $(ADDON) -x '*.DS_Store'

# Release build, named by version only, with checksum files to upload
# alongside it. Checksums are written from inside $(DIST) so they list the
# bare file name and `md5sum -c` / `sha256sum -c` work on a download.
release: $(RELEASE_ZIP) $(RELEASE_ZIP).md5 $(RELEASE_ZIP).sha256

$(RELEASE_ZIP): $(SRC)
	mkdir -p $(DIST)
	rm -f $(RELEASE_ZIP)
	zip -r $(RELEASE_ZIP) $(ADDON) -x '*.DS_Store'

$(RELEASE_ZIP).md5: $(RELEASE_ZIP)
	cd $(DIST) && md5sum $(notdir $<) > $(notdir $@)

$(RELEASE_ZIP).sha256: $(RELEASE_ZIP)
	cd $(DIST) && sha256sum $(notdir $<) > $(notdir $@)

clean:
	rm -rf $(DIST)
