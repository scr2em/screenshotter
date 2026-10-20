APP_NAME = Screenshotter
BUILD_APP = build/$(APP_NAME).app
INSTALL_DIR ?= /Applications

.PHONY: build run install uninstall clean icon release

build:
	@Scripts/build_app.sh

run: build
	@pkill -x $(APP_NAME) || true
	@open $(BUILD_APP)

install: build
	@pkill -x $(APP_NAME) || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R $(BUILD_APP) "$(INSTALL_DIR)/"
	@open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	@pkill -x $(APP_NAME) || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

icon:
	@swift Scripts/make_icon.swift Resources/AppIcon.icns

release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=x.y.z" && exit 1)
	@Scripts/release.sh $(VERSION)

clean:
	@rm -rf .build build
