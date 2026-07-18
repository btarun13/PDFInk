# PDFInk build. Uses swiftc directly because this machine's Command Line Tools
# install is half-updated: SPM's manifest/explicit-module pipeline fails against
# the mismatched SDK (see scripts/fix-swiftpm.sh header), while plain swiftc
# builds work. Package.swift is kept for use with a healthy toolchain/Xcode.

BUILD    := build
APP      := dist/PDFInk.app
CORE_SRC := $(wildcard Sources/PDFInkCore/*.swift)
APP_SRC  := $(wildcard Sources/PDFInk/*.swift)
TEST_SRC := $(wildcard Tests/PDFInkCoreTests/*.swift)
# -vfsoverlay masks a stale duplicate modulemap left behind by a half-updated
# CLT install (usr/include/swift/module.modulemap vs bridging.modulemap both
# defining SwiftBridging), which otherwise breaks every SDK interface build.
SWIFTFLAGS := -g -Onone -vfsoverlay .clt-fix/overlay.yaml

.PHONY: all app run test clean

all: app

$(BUILD)/libPDFInkCore.a: $(CORE_SRC)
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -static -emit-library -module-name PDFInkCore \
	  -emit-module -emit-module-path $(BUILD)/PDFInkCore.swiftmodule \
	  -o $@ $(CORE_SRC)

$(BUILD)/PDFInk: $(APP_SRC) $(BUILD)/libPDFInkCore.a
	swiftc $(SWIFTFLAGS) -I $(BUILD) -o $@ $(APP_SRC) $(BUILD)/libPDFInkCore.a

$(BUILD)/PDFInkTests: $(TEST_SRC) $(BUILD)/libPDFInkCore.a
	swiftc $(SWIFTFLAGS) -I $(BUILD) -o $@ $(TEST_SRC) $(BUILD)/libPDFInkCore.a

app: $(BUILD)/PDFInk
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BUILD)/PDFInk $(APP)/Contents/MacOS/PDFInk
	@cp scripts/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP) >/dev/null 2>&1 || true
	@echo "Built $(APP)"

run: app
	$(APP)/Contents/MacOS/PDFInk

test: $(BUILD)/PDFInkTests
	$(BUILD)/PDFInkTests

clean:
	rm -rf $(BUILD) dist
