# OilVoice — Haas-ja-v1.0 (speech.cpp) を使った macOS 音声入力アプリ
#
#   make            開発版 build/OilVoice Dev.app を作る（製品版と並べて使える）
#   make run        開発版をビルドして起動
#   make release    製品版 build/OilVoice.app を作る
#   make install    製品版を /Applications にコピー
#   make dist       製品版の DMG・ZIP・SHA256SUMS.txt を dist/ に作る（リリース用）
#   make clean      アプリのビルド成果物を消す（speech.cpp のビルドは残す）

# 開発版はバンドル ID と名前を変え、設定・キーチェーン・ログ・許可を製品版と分ける
ifeq ($(RELEASE),1)
APP_NAME    := OilVoice
BUNDLE_ID   := jp.contrea.oilvoice
else
APP_NAME    := OilVoice Dev
BUNDLE_ID   := jp.contrea.oilvoice.dev
endif
VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
SPEECH_DIR  := vendor/speech.cpp
SPEECH_BLD  := $(SPEECH_DIR)/build
BUILD       := build
APP         := $(BUILD)/$(APP_NAME).app
EXE         := OilVoice
MIN_MACOS   := 14.0
SOURCES     := $(wildcard Sources/*.swift)
SPEECH_LIB  := $(SPEECH_BLD)/libspeech-static.a

.PHONY: all speech app run release install dist clean distclean

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
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
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
	  -o "$(APP)/Contents/MacOS/$(EXE)"
	strip -x "$(APP)/Contents/MacOS/$(EXE)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleName -string "$(APP_NAME)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/" 2>/dev/null || true
	cp THIRD_PARTY_NOTICES.md "$(APP)/Contents/Resources/"
	@mkdir -p "$(APP)/Contents/Resources/Licenses"
	cp LICENSES/* "$(APP)/Contents/Resources/Licenses/"
	@# 指定要件をバンドル ID にして、ビルドし直してもアクセシビリティの許可とキーチェーンが残るようにする
	printf 'designated => identifier "%s"\n' "$(BUNDLE_ID)" > $(BUILD)/designated.req
	codesign --force --sign "$${CODESIGN_IDENTITY:--}" \
	  --entitlements Resources/OilVoice.entitlements \
	  $$( [ -z "$$CODESIGN_IDENTITY" ] && echo "-r $(BUILD)/designated.req" ) \
	  --options runtime "$(APP)"
	@echo
	@du -sh "$(APP)"
	@echo "→ $(APP)"

run: app
	open "$(APP)"

release:
	$(MAKE) app RELEASE=1

install: release
	rm -rf /Applications/OilVoice.app
	cp -R $(BUILD)/OilVoice.app /Applications/
	@echo "→ /Applications/OilVoice.app"

# リリースに載せる 3 つ。アプリの自動アップデートは ZIP と SHA256SUMS.txt を使う
dist: release
	@mkdir -p dist
	rm -rf $(BUILD)/dmg && mkdir -p $(BUILD)/dmg
	cp -R $(BUILD)/OilVoice.app $(BUILD)/dmg/ && ln -s /Applications $(BUILD)/dmg/Applications
	hdiutil create -quiet -volname OilVoice -srcfolder $(BUILD)/dmg -format UDZO -ov dist/OilVoice-$(VERSION)-macos-arm64.dmg
	rm -rf $(BUILD)/dmg dist/OilVoice-$(VERSION)-macos-arm64.zip
	cd $(BUILD) && ditto -c -k --keepParent OilVoice.app ../dist/OilVoice-$(VERSION)-macos-arm64.zip
	cd dist && shasum -a 256 OilVoice-$(VERSION)-macos-arm64.dmg OilVoice-$(VERSION)-macos-arm64.zip > SHA256SUMS.txt
	@cat dist/SHA256SUMS.txt

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf $(SPEECH_BLD)
