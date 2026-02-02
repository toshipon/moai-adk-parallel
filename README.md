# MoAI Parallel SPEC Executor

複数の SPEC（仕様書）を Git Worktree と tmux で並列実行するオーケストレーションツールです。

## 🚀 概要

MoAI Parallel SPEC Executor は、以下の処理を自動化します：

1. **main ブランチの自動同期** - 実行前に最新コードを取得
2. **SPEC の自動検出** - ステータス（draft, in_progress など）でフィルタリング
3. **Git Worktree の自動作成** - 各 SPEC 用の独立した開発環境を構築
4. **tmux による並列実行** - 複数の Claude Code セッションを同時管理
5. **リアルタイム監視** - 実行状況とログの集約表示

## 📋 前提条件

- Claude CLI がインストール済み
- tmux がインストール済み（macOS: `brew install tmux`）
- Git リポジトリ内で作業

## 🛠️ セットアップ

```bash
# リポジトリをクローン
git clone https://github.com/toshipon/moai-adk-parallel.git
cd moai-adk-parallel

# スクリプトに実行権限を付与（すでに付与済み）
chmod +x scripts/moai-parallel.sh scripts/moai-monitor.sh
```

## 📖 使い方

### 1. 対象 SPEC の確認

```bash
./scripts/moai-parallel.sh --list
```

出力例：
```
============================================================================
  MoAI Parallel SPEC Executor
============================================================================

[INFO] 対象ステータス: draft

┌─────────────────────────────────────────────────────────────────┐
│ 対象 SPEC 一覧 (3 件)                                          │
├─────────────────────────────────────────────────────────────────┤
│  📋 SPEC-SAMPLE-A-001
│  📋 SPEC-SAMPLE-B-001
│  📋 SPEC-SAMPLE-C-001
└─────────────────────────────────────────────────────────────────┘
```

### 2. 実行計画のプレビュー

```bash
./scripts/moai-parallel.sh --dry-run
```

### 3. 並列実行の開始

```bash
./scripts/moai-parallel.sh
```

### 4. 実行状況の確認

```bash
# tmux セッションにアタッチ
tmux attach -t moai-parallel

# または監視ツールを使用
./scripts/moai-monitor.sh --watch
```

## 🎮 tmux 基本操作

| キー | 操作 |
|------|------|
| `Ctrl+b n` | 次のウィンドウ（次の SPEC） |
| `Ctrl+b p` | 前のウィンドウ |
| `Ctrl+b 0-9` | ウィンドウ番号で直接移動 |
| `Ctrl+b d` | デタッチ（バックグラウンド継続） |
| `Ctrl+b w` | ウィンドウ一覧を表示 |

## 📁 ディレクトリ構成

```
moai-adk-parallel/
├── README.md                    # このファイル
├── scripts/
│   ├── moai-parallel.sh         # 並列実行オーケストレータ
│   └── moai-monitor.sh          # ステータス監視ツール
└── .moai/
    ├── specs/                   # SPEC ファイル格納
    │   ├── SPEC-SAMPLE-A-001/
    │   │   └── spec.md
    │   ├── SPEC-SAMPLE-B-001/
    │   │   └── spec.md
    │   └── SPEC-SAMPLE-C-001/
    │       └── spec.md
    └── logs/
        └── parallel/            # 実行ログ格納
```

## ⚙️ コマンドリファレンス

### moai-parallel.sh

```bash
./scripts/moai-parallel.sh [options]
```

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `-s, --status STATUS` | 対象 SPEC のステータス | `draft` |
| `-n, --max-parallel N` | 最大並列数 | `4` |
| `-d, --dry-run` | 実行せずにプレビュー | - |
| `-l, --list` | 対象 SPEC の一覧表示 | - |
| `--no-sync` | main 同期をスキップ | - |
| `-h, --help` | ヘルプ表示 | - |

### moai-monitor.sh

```bash
./scripts/moai-monitor.sh [options]
```

| オプション | 説明 |
|-----------|------|
| `-w, --watch` | リアルタイム監視（5秒更新） |
| `-l, --logs` | ログファイル一覧 |
| `-s, --summary` | 完了サマリー |
| `-h, --help` | ヘルプ表示 |

## 🔧 カスタマイズ

### SPEC ファイルの追加

`.moai/specs/` 配下に新しいディレクトリを作成し、`spec.md` を追加します：

```bash
mkdir -p .moai/specs/SPEC-YOUR-FEATURE-001
```

`spec.md` の必須フィールド：

```yaml
---
code: SPEC-YOUR-FEATURE-001
title: 機能名
status: draft  # draft, in_progress, review, completed
# ... その他のフィールド
---
```

### 並列数の調整

マシンスペックに応じて並列数を調整：

| RAM | 推奨並列数 |
|-----|-----------|
| 8GB | 2 |
| 16GB | 3-4 |
| 32GB+ | 4-6 |

```bash
./scripts/moai-parallel.sh --max-parallel 2
```

## 🐛 トラブルシューティング

### tmux セッションが既に存在する

```bash
tmux kill-session -t moai-parallel
```

### Worktree エラー

```bash
# Worktree 状態を確認
git worktree list

# 破損した Worktree を修復
git worktree prune
```

## 📚 関連リンク

- [Zenn 記事: Claude Code で複数タスクを並列実行する MoAI Parallel SPEC Executor](https://zenn.dev/)
- [MoAI-ADK リポジトリ](https://github.com/toshipon/kaizen-lab)

## 📄 ライセンス

MIT License
