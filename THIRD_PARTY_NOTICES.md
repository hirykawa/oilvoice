# OilVoice が使っているオープンソース

OilVoice は次のソフトウェアとモデルを使っています。各ライセンスの全文は、アプリの
`Contents/Resources/Licenses/`（ソースでは `LICENSES/`）にあります。

## アプリに組み込んでいるもの

| 名前 | 用途 | ライセンス | 著作権者 | 入手元 |
|---|---|---|---|---|
| speech.cpp 0.10.1 | 音声認識・音声区間検出の実行エンジン（静的リンク） | MIT License | Copyright (c) 2026 Sakasegawa | https://github.com/nyosegawa/speech.cpp |
| ggml（speech.cpp の submodule） | 推論ライブラリ（Metal） | MIT License | Copyright (c) 2023-2026 The ggml authors | https://github.com/nyosegawa/ggml |

## 初回起動時にダウンロードするモデル

モデルはアプリに同梱せず、初回起動時に Hugging Face から取得します（固定リビジョン・SHA-256 で確認）。

| 名前 | 用途 | ライセンス | 著作権者 | 入手元 |
|---|---|---|---|---|
| Haas-ja-v1.0（GGUF 版） | 日本語の音声認識 | Apache License 2.0 | Third Intelligence（GGUF 変換：sakasegawa） | https://huggingface.co/third-intelligence/Haas-ja-v1.0 / https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF |
| Silero VAD v6.2（GGUF 版） | 話している区間の検出 | MIT License | Copyright (c) 2020-present Silero Team | https://github.com/snakers4/silero-vad / https://huggingface.co/sakasegawa/silero-vad-GGUF |

Haas-ja-v1.0 GGUF は speech.cpp の `convert.py` と `speech quantize` で元のチェックポイントから変換・量子化されたものです。
OilVoice はモデルの重みを改変していません。

## 外部サービス（任意）

AI 整形を有効にしたときだけ、確定した文字（音声ではありません）を次のサービスに送ります。

- ChatGPT（OpenAI）：ChatGPT アカウントでログインし、Codex と同じ経路でサブスクリプションの利用枠を使います。
  OpenAI の利用規約に従ってお使いください。
- OpenCode Go：利用者自身の API キーで呼び出します。
