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

## ビルド

Xcode（Command Line Tools）と CMake が必要です。

```sh
git clone --recurse-submodules https://github.com/hirykawa/oilvoice.git
cd oilvoice
brew install cmake
make            # speech.cpp を静的ライブラリでビルド → build/OilVoice.app
make run        # ビルドして起動
make install    # /Applications にコピー
```

初回起動時の流れ：

1. アクセシビリティの許可を求められます（キー監視と入力に必要）。
   「システム設定 › プライバシーとセキュリティ › アクセシビリティ」で OilVoice をオンにしてください。
2. マイクの許可を求められます。
3. モデル（約 0.35 GB）をダウンロードし、読み込みます。メニューバーのアイコンから状態が見られます。

> 署名は ad-hoc ですが、指定要件をバンドル ID（`jp.contrea.oilvoice`）にしているので、ビルドし直してもアクセシビリティの許可は残ります。
> 開発者証明書があれば `CODESIGN_IDENTITY="Developer ID Application: ..." make` で署名できます。

## 設定

メニューバーの波形アイコン › 設定…

- **ショートカット**：「同じキーを2回」（Return・右⌘・fn など）か「キーの組み合わせ」（⌥Space など）
- **辞書**：表記と読み。Haas の `keywords` に渡し、認識後にも読み→表記の置換をかけます
- **AI 整形**：ChatGPT（ログイン）/ OpenCode Go（API キー）、モデル、指示文、タイムアウト
- **モデル**：Q4_K / Q5_K / Q6_K / Q8_0 の切り替え

トークンと API キーはログインキーチェーンに保存します。

## ログ

動作ログを `~/Library/Logs/OilVoice.log` に書きます（認識したテキストを含みます。音声は残しません）。

## ライセンス

OilVoice のコードは [MIT License](LICENSE) です。組み込んでいる OSS とモデルのライセンスは
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) と `LICENSES/` を参照してください（アプリ内の「設定 › ライセンス」でも表示）。
