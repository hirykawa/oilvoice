# OilVoice — Haas-ja-v1.0 (speech.cpp) を使った macOS 音声入力アプリ
#
#   make            speech.cpp を静的ライブラリとしてビルドし、build/OilVoice.app を作る
#   make run        ビルドして起動
#   make install    /Applications にコピー
#   make clean      アプリのビルド成果物を消す（speech.cpp のビルドは残す）

APP_NAME    := OilVoice
BUNDLE_ID   := jp.contrea.oilvoice
SPEECH_DIR  := vendor/speech.cpp
SPEECH_BLD  := $(SPEECH_DIR)/build
BUILD       := build
APP         := $(BUILD)/$(APP_NAME).app
MIN_MACOS   := 14.0
SOURCES     := $(wildcard Sources/*.swift)
SPEECH_LIB  := $(SPEECH_BLD)/libspeech-static.a

.PHONY: all speech app run install clean distclean

all: app

# speech.cpp: Metal を埋め込んだ静的ライブラリ。CLI・サーバーは作らない。
$(SPEECH_LIB):
	cmake -S $(SPEECH_DIR) -B $(SPEECH_BLD) \
	  -DCMAKE_BUILD_TYPE=Release \
	  -DBUILD_SHARED_LIBS=OFF \
	  -DGGML_NATIVE=OFF \
	  -DGGML_METAL=ON \
	  -DGGML_METAL_EMBED_LIBRARY=ON \
	  -DCMAKE_OSX_ARCHITECTURES=arm64 \
	  -DCMAKE_OSX_DEPLOYMENT_TARGET=$(MIN_MACOS)
	cmake --build $(SPEECH_BLD) --config Release --target speech-static -j

speech: $(SPEECH_LIB)

app: $(SPEECH_LIB) $(SOURCES) Resources/Info.plist
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -wmo -swift-version 5 \
	  -target arm64-apple-macos$(MIN_MACOS) \
	  -import-objc-header Sources/Bridge.h \
	  -I $(SPEECH_DIR)/include \
	  $(SOURCES) \
	  $$(find $(SPEECH_BLD) -name '*.a' | sort) \
	  -lc++ \
	  -framework Accelerate -framework Metal -framework Foundation \
	  -framework AppKit -framework SwiftUI -framework AVFoundation \
	  -framework ApplicationServices -framework Carbon -framework Security \
	  -framework Network -framework CryptoKit -framework ServiceManagement \
	  -Xlinker -dead_strip \
	  -o $(APP)/Contents/MacOS/$(APP_NAME)
	strip -x $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/ 2>/dev/null || true
	cp THIRD_PARTY_NOTICES.md $(APP)/Contents/Resources/
	@mkdir -p $(APP)/Contents/Resources/Licenses
	cp LICENSES/* $(APP)/Contents/Resources/Licenses/
	codesign --force --sign "$${CODESIGN_IDENTITY:--}" \
	  --entitlements Resources/OilVoice.entitlements \
	  $$( [ -z "$$CODESIGN_IDENTITY" ] && echo "-r Resources/designated.req" ) \
	  --options runtime $(APP)
	@echo
	@du -sh $(APP)
	@echo "→ $(APP)"

run: app
	open $(APP)

install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "→ /Applications/$(APP_NAME).app"

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf $(SPEECH_BLD)
