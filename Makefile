APP      := whispr.app
BINARY   := .build/release/whispr
IDENTITY ?= whispr-dev

.PHONY: all build bundle sign run clean

all: bundle sign

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/whispr
	cp Resources/Info.plist $(APP)/Contents/Info.plist

# Signs with the stable self-signed identity if it exists (create it once in
# Keychain Access: Certificate Assistant -> Create a Certificate -> name
# "whispr-dev", type "Code Signing"). Falls back to ad-hoc signing, which works
# but resets TCC permission grants (Accessibility/Microphone) on every rebuild.
sign:
	@if security find-identity -v -p codesigning | grep -q "$(IDENTITY)"; then \
		echo "Signing with $(IDENTITY)"; \
		codesign --force --sign "$(IDENTITY)" $(APP); \
	else \
		echo "Identity '$(IDENTITY)' not found - ad-hoc signing (TCC grants reset each rebuild)"; \
		codesign --force --sign - $(APP); \
	fi

run: all
	open $(APP)

clean:
	rm -rf .build $(APP)
