ADDON   := MyXPBar
VERSION := $(shell sed -n 's/^## Version: *//p' $(ADDON)/$(ADDON).toc | head -1)
DIST    := dist
ZIP     := $(DIST)/$(ADDON)-$(VERSION).zip

SRC := $(ADDON)/$(ADDON).lua $(ADDON)/$(ADDON).toc

.PHONY: all zip clean

all: zip

zip: $(ZIP)

$(ZIP): $(SRC)
	mkdir -p $(DIST)
	rm -f $(ZIP)
	zip -r $(ZIP) $(ADDON) -x '*.DS_Store'

clean:
	rm -rf $(DIST)
