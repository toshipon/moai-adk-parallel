---
code: SPEC-SAMPLE-B-001
title: サンプル機能 B の実装
status: draft
created_at: 2026-02-02
updated_at: 2026-02-02
priority: medium
effort: 2
version: "1.0.0"
epic: SAMPLE
domains:
  - frontend
  - ui
depends_on: []
related_specs:
  - SPEC-SAMPLE-A-001
risks: |
  - サンプル用のため実際のリスクはなし
tags:
  - sample
  - demo
  - parallel-execution
---

# SPEC-SAMPLE-B-001: サンプル機能 B の実装

## Overview

これは MoAI Parallel SPEC Executor のデモ用サンプル SPEC です。
SPEC-SAMPLE-A-001 と並列で実行されることを想定しています。

### 背景

並列実行では、複数の独立した SPEC が同時に処理されます。
この SPEC は並列実行のデモ用です。

### 目的

1. 並列実行時の独立性確認
2. Worktree 分離のデモ
3. 複数ウィンドウ管理のテスト

## Requirements

### Functional Requirements

| ID | 要件 | 優先度 |
|----|------|--------|
| FR-001 | サンプル UI コンポーネントを作成する | Must |
| FR-002 | スタイルを適用する | Should |

### Non-Functional Requirements

| ID | 要件 | 基準値 |
|----|------|--------|
| NFR-001 | 実行時間 | 1分以内 |

## Acceptance Criteria

- [ ] UI コンポーネントが作成される
- [ ] スタイルが適用される
- [ ] 他の SPEC と干渉しない
