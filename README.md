# OilVoice

Haas-ja-v1.0（日本語音声認識）を Mac の中で動かす、メニューバー常駐の音声入力アプリです。

- **Space を2回**押すと、入力欄の近くにパネルが出て、話した内容がリアルタイムに表示されます
- **Return** で確定して入力欄に入力、**Esc** で取り消し
- 話している間は、話し始めからの音声全体を 0.2 秒ごとに認識し直すので、文脈が切れず、前の部分も直っていきます
- 最後に **「送信して」** と言うと、話し終えた時点で入力して Return まで押します
- 辞書（固有名詞の表記と読み）を Haas のカスタム語彙として使い、認識を強めます
- 音声・動画ファイルを入れると文字起こし（テキスト / 時刻付き / SRT）
- AI 整形（任意）：ChatGPT でログインしてサブスク枠を使う、または OpenCode Go の API キー

## 構成

| 部分 | 中身 |
|---|---|
| UI | Swift + AppKit / SwiftUI。Electron などは使わず、アプリ本体は数 MB |
| 音声認識 | [speech.cpp](https://github.com/nyosegawa/speech.cpp)（MIT）を静的リンク、Metal（GPU）で実行 |
| モデル | Haas-ja-v1.0 GGUF Q4_K（0.35 GB、既定）と Silero VAD（1.2 MB）を初回起動時にダウンロード |
| リアルタイム表示 | 確定位置から今までの音声全体を約 0.2 秒ごとに丸ごと認識し直す。25 秒を超えたら Silero VAD で見つけた息継ぎ（なければ最も静かな瞬間）までを確定 |
| 小さいマイク対策 | 自動ゲイン（最大 80 倍）。待機中もマイクを開いて直前 1 秒を保持し、話し始めを落とさない（設定でオフにできる） |
| 入力 | クリップボード経由の ⌘V（元のクリップボードは戻す） |

M5 で 10 秒前後の発話が 0.04 秒ほどで認識できるモデルなので、確定してから入力までほぼ待ちません。

## ローカルで起動する

### 必要なもの

- Apple シリコン（M1 以降）の Mac、macOS 14 以降
- Xcode Command Line Tools（`swiftc` と macOS SDK）
- CMake と Git（Homebrew で入れる）
- 空き容量 約 1 GB（モデル 0.35 GB とビルド成果物）

```sh
xcode-select --install        # 入っていなければ
brew install cmake git
```

### 1. 取得してビルドする

```sh
git clone --recurse-submodules https://github.com/hirykawa/oilvoice.git
cd oilvoice
make
```

- `--recurse-submodules` を付けると、speech.cpp と ggml も一緒に取得します。付け忘れたら `git submodule update --init --recursive` を実行してください。
- 初回の `make` は speech.cpp のビルドを含むので数分かかります。2 回目以降はアプリ部分だけで数十秒です。
- できあがるのは `build/OilVoice.app`（約 9 MB）です。

### 2. 起動する

```sh
make run                      # ビルドして build/OilVoice.app を起動
# または
make install                  # /Applications/OilVoice.app にコピー
open /Applications/OilVoice.app
```

ウィンドウは開かず、**メニューバーに波形のアイコン**が出ます。ここから設定や状態を確認できます。

### 3. 初回だけ必要な設定

1. **アクセシビリティを許可する**
   起動すると許可を求められ、設定画面が開きます。
   「システム設定 › プライバシーとセキュリティ › アクセシビリティ」で **OilVoice をオン**にしてください。
   キーの監視（Space 2 回・Return・Esc）と、入力欄への入力に使います。
2. **マイクを許可する**
   確認ダイアログが出たら「許可」を押します。
3. **モデルのダウンロードを待つ**
   初回起動時に Haas-ja-v1.0（約 0.35 GB）と Silero VAD を Hugging Face から取得し、SHA-256 を確認して
   `~/Library/Application Support/OilVoice/Models/` に置きます。
   メニューバーのアイコンを押して「準備完了」と出れば使えます。

### 4. 使う

1. 文字を入れたい入力欄（Slack、メール、ブラウザなど）にカーソルを置く
2. **Space を素早く 2 回**押す → 入力欄の近くにパネルが出る（1 回目に入った空白は自動で消えます）
3. 話す → 話している途中から文字が表示される
4. **Return** で入力欄に入力。**Esc** で取り消し
5. 最後に「**送信して**」と言うと、話し終えた時点で入力して Return まで押します

音声ファイルの文字起こしは、メニューバーのアイコン › 「音声ファイルを文字起こし…」から。

### 終了・更新・削除

```sh
# 終了：メニューバーのアイコン › OilVoice を終了（または）
pkill -x OilVoice

# 更新
git pull --recurse-submodules
make                          # 必要なら make install も

# speech.cpp ごと作り直す
make distclean && make

# 削除
rm -rf /Applications/OilVoice.app build
rm -rf ~/Library/Application\ Support/OilVoice   # モデル
defaults delete jp.contrea.oilvoice               # 設定
```

### うまく動かないとき

| 症状 | 確認すること |
|---|---|
| Space 2 回でパネルが出ない | アクセシビリティで OilVoice がオンか。オンなのに反応しなければ、一度オフ→オンにするか `tccutil reset Accessibility jp.contrea.oilvoice` で許可をやり直す |
| パネルは出るが文字が出ない | 「システム設定 › プライバシーとセキュリティ › マイク」で OilVoice がオンか。ログ（下記）の `peakRMS` が 0 のままならマイクに音が届いていない |
| 「モデルを準備中です」と出る | ダウンロード中か失敗。設定 › モデル で状態を確認し、失敗なら「再試行」 |
| パネルが入力欄から離れた場所に出る | アプリがカーソル位置を公開していない（ターミナルや一部の Electron アプリ）。その場合はマウスのある画面の下部に出る |
| 話し始めが欠ける | 設定 › 一般 › マイク の「待機中もマイクを開いておく」をオンに |
| 認識が不正確 | Bluetooth ヘッドセットは通話用の音質になる。Mac 本体や有線のマイクのほうが精度が出る。固有名詞は辞書に登録 |

動作の詳細は `~/Library/Logs/OilVoice.log` に出ます（`tail -f ~/Library/Logs/OilVoice.log` で見ながら試せます）。

> 署名は ad-hoc ですが、指定要件をバンドル ID（`jp.contrea.oilvoice`）にしているので、ビルドし直してもアクセシビリティの許可は残ります。
> 開発者証明書があれば `CODESIGN_IDENTITY="Developer ID Application: ..." make` で署名できます。

### 開発用：マイクなしで試す

録音済みの音声ファイルをマイクの代わりに実時間で流し、起動と同時に入力を始められます。

```sh
open --env OILVOICE_FEED="$PWD/sample.wav" --env OILVOICE_AUTOSTART=1 build/OilVoice.app
tail -f ~/Library/Logs/OilVoice.log
```

`OILVOICE_OPEN_SETTINGS=1`（タブ番号）を付けると、起動時に設定画面を開きます。

## 設定

メニューバーの波形アイコン › 設定…

- **ショートカット**：「同じキーを2回」（既定は Space。右⌘・fn なども可）か「キーの組み合わせ」（⌥Space など）
- **辞書**：表記と読み。Haas の `keywords` に渡し、認識後にも読み→表記の置換をかけます
- **AI 整形**：ChatGPT（ログイン）/ OpenCode Go（API キー）、モデル、指示文、タイムアウト
- **モデル**：Q4_K / Q5_K / Q6_K / Q8_0 の切り替え

トークンと API キーはログインキーチェーンに保存します。

## ログ

動作ログを `~/Library/Logs/OilVoice.log` に書きます（認識したテキストを含みます。音声は残しません）。

## ライセンス

OilVoice のコードは [MIT License](LICENSE) です。組み込んでいる OSS とモデルのライセンスは
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) と `LICENSES/` を参照してください（アプリ内の「設定 › ライセンス」でも表示）。
