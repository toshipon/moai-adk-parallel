#!/bin/bash

# ============================================================================
# MoAI Parallel SPEC Executor
#
# 司令塔スクリプト: 複数の SPEC を worktree + tmux で並列実行
#
# Usage:
#   ./scripts/moai-parallel.sh [options]
#
# Options:
#   -s, --status STATUS    対象 SPEC のステータス (default: draft)
#   -n, --max-parallel N   最大並列数 (default: 4)
#   -d, --dry-run          実行せずにプレビューのみ
#   -l, --list             対象 SPEC の一覧表示のみ
#   -h, --help             ヘルプ表示
#
# Examples:
#   ./scripts/moai-parallel.sh --list                    # 着手可能 SPEC を確認
#   ./scripts/moai-parallel.sh --dry-run                 # 実行計画をプレビュー
#   ./scripts/moai-parallel.sh                           # 実行開始
#   ./scripts/moai-parallel.sh --status in_progress -n 3 # 進行中を3並列で
#
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPECS_DIR="${PROJECT_ROOT}/.moai/specs"
# メインリポジトリの名前から worktree ベースを決定
MAIN_REPO=$(git -C "${PROJECT_ROOT}" worktree list | head -1 | awk '{print $1}')
MAIN_REPO_NAME=$(basename "${MAIN_REPO}")
WORKTREE_BASE="${HOME}/.claude-worktrees/${MAIN_REPO_NAME}"
LOG_DIR="${PROJECT_ROOT}/.moai/logs/parallel"
TMUX_SESSION="moai-parallel"

# Default settings
TARGET_STATUS="draft,in-progress"  # カンマ区切りで複数指定可能
MAX_PARALLEL=4
DRY_RUN=false
LIST_ONLY=false
SKIP_SYNC=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_header() {
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}  MoAI Parallel SPEC Executor${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
}

show_help() {
    cat << EOF
MoAI Parallel SPEC Executor - 複数 SPEC の並列実行オーケストレータ

Usage: $0 [options]

Options:
  -s, --status STATUS    対象 SPEC のステータス (default: draft,in-progress)
                         カンマ区切りで複数指定可能: draft,in-progress,review
  -n, --max-parallel N   最大並列数 (default: 4)
  -d, --dry-run          実行せずにプレビューのみ
  -l, --list             対象 SPEC の一覧表示のみ
  --no-sync              main ブランチの同期をスキップ
  -h, --help             このヘルプを表示

Examples:
  $0 --list                           # 着手可能 SPEC を確認 (draft + in-progress)
  $0 --dry-run                        # 実行計画をプレビュー
  $0                                  # draft + in-progress の SPEC を実行
  $0 --status draft                   # draft のみ実行
  $0 --status in_progress -n 3        # 進行中を3並列で実行
  $0 --no-sync                        # main 同期なしで実行

Workflow:
  1. main ブランチを最新化 (git fetch & pull)
  2. SPEC 検出 → ステータスでフィルタリング
  3. Worktree 作成 → 各 SPEC 用の独立環境 + main マージ
  4. tmux 起動 → 並列でペインを分割
  5. Claude Code 実行 → /moai:2-run SPEC-XXX
  6. 結果監視 → ログ集約・ステータス更新

EOF
}

# ============================================================================
# Main Branch Sync
# ============================================================================

sync_main_branch() {
    log_info "🔄 main ブランチを最新化しています..."

    # メインリポジトリで main を更新
    if ! git -C "${MAIN_REPO}" fetch origin main 2>/dev/null; then
        log_warn "リモートからの fetch に失敗しました（オフライン？）"
        return 1
    fi

    # 現在のブランチを保存
    local current_branch=$(git -C "${MAIN_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # main ブランチを更新
    git -C "${MAIN_REPO}" checkout main 2>/dev/null
    git -C "${MAIN_REPO}" pull origin main 2>/dev/null

    # 元のブランチに戻る
    if [[ -n "${current_branch}" && "${current_branch}" != "main" ]]; then
        git -C "${MAIN_REPO}" checkout "${current_branch}" 2>/dev/null
    fi

    log_success "main ブランチを最新化しました"
    return 0
}

sync_worktree_with_main() {
    local worktree_path="$1"
    local spec_name="$2"

    log_info "🔄 ${spec_name}: main ブランチをマージしています..."

    # worktree で main をマージ (stdout/stderr both to stderr)
    if git -C "${worktree_path}" merge origin/main --no-edit >&2 2>&1; then
        log_success "${spec_name}: main マージ完了"
        return 0
    else
        # コンフリクトが発生した場合
        log_warn "${spec_name}: マージコンフリクト発生 - 手動解決が必要です"
        git -C "${worktree_path}" merge --abort >&2 2>&1
        return 1
    fi
}

# ============================================================================
# SPEC Detection
# ============================================================================

find_specs_by_status() {
    local target_statuses="$1"  # カンマ区切りで複数指定可能
    local specs=()

    if [[ ! -d "${SPECS_DIR}" ]]; then
        log_error "SPEC ディレクトリが見つかりません: ${SPECS_DIR}"
        return 1
    fi

    # ターゲットステータスを配列に変換（正規化済み）
    local -a normalized_targets=()
    IFS=',' read -ra status_array <<< "${target_statuses}"
    for ts in "${status_array[@]}"; do
        normalized_targets+=("$(echo "${ts}" | tr '_' '-')")
    done

    while IFS= read -r spec_file; do
        local spec_dir=$(dirname "${spec_file}")
        local spec_name=$(basename "${spec_dir}")
        local status=$(grep -E "^status:" "${spec_file}" 2>/dev/null | sed 's/status:[[:space:]]*//' | tr -d '[:space:]')
        # ステータスを正規化
        local normalized_status
        normalized_status=$(echo "${status}" | tr '_' '-')

        # ターゲットステータスのいずれかにマッチするかチェック
        for target in "${normalized_targets[@]}"; do
            if [[ "${normalized_status}" == "${target}" ]]; then
                specs+=("${spec_name}")
                break
            fi
        done
    done < <(find "${SPECS_DIR}" -name "spec.md" -type f 2>/dev/null)

    # 配列が空でない場合のみ出力
    if [[ ${#specs[@]} -gt 0 ]]; then
        printf '%s\n' "${specs[@]}"
    fi
}

list_specs() {
    local target_status="$1"

    print_header
    log_info "対象ステータス: ${target_status}"
    echo ""

    local specs=()
    while IFS= read -r spec; do
        [[ -n "${spec}" ]] && specs+=("${spec}")
    done < <(find_specs_by_status "${target_status}")

    if [[ ${#specs[@]} -eq 0 ]]; then
        log_warn "ステータス '${target_status}' の SPEC が見つかりません"
        return 0
    fi

    echo -e "${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│ 対象 SPEC 一覧 (${#specs[@]} 件)                                        │${NC}"
    echo -e "${GREEN}├─────────────────────────────────────────────────────────────────┤${NC}"

    for spec in "${specs[@]}"; do
        echo -e "${GREEN}│${NC}  📋 ${spec}"
    done

    echo -e "${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ============================================================================
# Worktree Management
# ============================================================================

generate_worktree_name() {
    local spec_name="$1"
    # SPEC-XXX-YYY-001 → xxx-yyy-001
    echo "${spec_name}" | sed 's/^SPEC-//' | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

create_worktree_for_spec() {
    local spec_name="$1"
    local sync_main="${2:-true}"  # デフォルトで main を同期
    local worktree_name=$(generate_worktree_name "${spec_name}")
    local worktree_path="${WORKTREE_BASE}/${worktree_name}"
    local branch_name="feature/${spec_name}"

    # 既存チェック
    if [[ -d "${worktree_path}" ]]; then
        log_info "Worktree 既存: ${worktree_path}"

        # 既存 worktree でも main を同期
        if [[ "${sync_main}" == "true" ]]; then
            sync_worktree_with_main "${worktree_path}" "${spec_name}"
        fi

        echo "${worktree_path}"
        return 0
    fi

    # メインリポジトリから作成
    local main_repo=$(git -C "${PROJECT_ROOT}" worktree list | head -1 | awk '{print $1}')

    log_info "Worktree 作成中: ${worktree_path}"

    # ブランチが存在するか確認
    if git -C "${main_repo}" show-ref --verify --quiet "refs/heads/${branch_name}"; then
        git -C "${main_repo}" worktree add "${worktree_path}" "${branch_name}" >&2
        # 既存ブランチの場合も main を同期
        if [[ "${sync_main}" == "true" ]]; then
            sync_worktree_with_main "${worktree_path}" "${spec_name}" >&2
        fi
    else
        # main から新規ブランチ作成（最新の main から作成されるので同期不要）
        git -C "${main_repo}" worktree add -b "${branch_name}" "${worktree_path}" main >&2
        log_success "${spec_name}: 最新の main から新規ブランチ作成"
    fi

    echo "${worktree_path}"
}

# ============================================================================
# tmux Session Management
# ============================================================================

setup_tmux_session() {
    local specs=("$@")
    local num_specs=${#specs[@]}

    # 既存セッションを終了
    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        log_warn "既存の tmux セッション '${TMUX_SESSION}' を終了します"
        tmux kill-session -t "${TMUX_SESSION}"
    fi

    log_info "tmux セッション '${TMUX_SESSION}' を作成中..."

    # 新規セッション作成（最初のペイン）
    local first_spec="${specs[0]}"
    local first_worktree=$(create_worktree_for_spec "${first_spec}")

    tmux new-session -d -s "${TMUX_SESSION}" -c "${first_worktree}"
    tmux rename-window -t "${TMUX_SESSION}:0" "${first_spec}"

    # 残りのペインを作成
    for ((i=1; i<num_specs && i<MAX_PARALLEL; i++)); do
        local spec="${specs[i]}"
        local worktree=$(create_worktree_for_spec "${spec}")

        # 新しいウィンドウを作成
        tmux new-window -t "${TMUX_SESSION}" -n "${spec}" -c "${worktree}"
    done

    # 各ウィンドウで Claude Code を起動するコマンドを送信
    for ((i=0; i<num_specs && i<MAX_PARALLEL; i++)); do
        local spec="${specs[i]}"
        local worktree_path
        worktree_path=$(create_worktree_for_spec "${spec}")

        # ログファイルのパス
        local log_file="${LOG_DIR}/${spec}-$(date +%Y%m%d-%H%M%S).log"
        mkdir -p "${LOG_DIR}"

        # Claude Code 起動コマンド（フルサイクル: 2-run → 3-sync → PR作成、自動進行モード）
        # script コマンドで画面表示とログ記録を両立
        local claude_cmd="cd '${worktree_path}' && script -q '${log_file}' claude --dangerously-skip-permissions '/moai:2-run ${spec} を実行してください。完了したら /moai:3-sync ${spec} を実行し、最後に gh pr create でPRを作成してください。【重要】AskUserQuestion は使用せず、最適な選択肢を自動で判断して進めてください。確認なしで自律的に完了まで進めてください。日本語で応答してください。'"

        tmux send-keys -t "${TMUX_SESSION}:${i}" "${claude_cmd}" C-m

        log_info "Claude Code 起動: ${spec} → ${worktree_path}"
    done

    log_success "tmux セッション準備完了"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│ 実行中のセッションにアタッチするには:                           │${NC}"
    echo -e "${CYAN}│                                                                 │${NC}"
    echo -e "${CYAN}│   tmux attach -t ${TMUX_SESSION}                                    │${NC}"
    echo -e "${CYAN}│                                                                 │${NC}"
    echo -e "${CYAN}│ ウィンドウ切り替え: Ctrl+b n (次) / Ctrl+b p (前)              │${NC}"
    echo -e "${CYAN}│ デタッチ: Ctrl+b d                                              │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ============================================================================
# Dry Run Preview
# ============================================================================

preview_execution() {
    local specs=("$@")

    print_header
    log_info "🔍 DRY RUN モード - 実行計画のプレビュー"
    echo ""

    local sync_status="有効"
    if [[ "${SKIP_SYNC}" == true ]]; then
        sync_status="スキップ (--no-sync)"
    fi

    echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│ 実行計画                                                        │${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│ 対象 SPEC: ${#specs[@]} 件${NC}"
    echo -e "${YELLOW}│ 最大並列数: ${MAX_PARALLEL}${NC}"
    echo -e "${YELLOW}│ 実行バッチ数: $(( (${#specs[@]} + MAX_PARALLEL - 1) / MAX_PARALLEL ))${NC}"
    echo -e "${YELLOW}│ main 同期: ${sync_status}${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    local batch=1
    local count=0

    echo -e "${BLUE}バッチ ${batch}:${NC}"

    for spec in "${specs[@]}"; do
        local worktree_name=$(generate_worktree_name "${spec}")
        local worktree_path="${WORKTREE_BASE}/${worktree_name}"
        local exists="(新規作成)"

        if [[ -d "${worktree_path}" ]]; then
            exists="(既存)"
        fi

        echo "  📋 ${spec}"
        echo "     └─ Worktree: ${worktree_path} ${exists}"
        echo "     └─ Command: claude '/moai:2-run ${spec}'"
        echo ""

        ((count++))

        if (( count % MAX_PARALLEL == 0 && count < ${#specs[@]} )); then
            ((batch++))
            echo -e "${BLUE}バッチ ${batch}:${NC}"
        fi
    done

    echo ""
    log_info "実行するには: $0 (--dry-run オプションなしで)"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--status)
                TARGET_STATUS="$2"
                shift 2
                ;;
            -n|--max-parallel)
                MAX_PARALLEL="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -l|--list)
                LIST_ONLY=true
                shift
                ;;
            --no-sync)
                SKIP_SYNC=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Sync main branch first (unless skipped or list-only mode)
    if [[ "${SKIP_SYNC}" != true && "${LIST_ONLY}" != true ]]; then
        sync_main_branch
    fi

    # List only mode
    if [[ "${LIST_ONLY}" == true ]]; then
        list_specs "${TARGET_STATUS}"
        exit 0
    fi

    # Find target specs
    local specs=()
    while IFS= read -r spec; do
        [[ -n "${spec}" ]] && specs+=("${spec}")
    done < <(find_specs_by_status "${TARGET_STATUS}")

    if [[ ${#specs[@]} -eq 0 ]]; then
        print_header
        log_warn "ステータス '${TARGET_STATUS}' の SPEC が見つかりません"
        log_info "利用可能なステータスを確認: $0 --status draft --list"
        exit 0
    fi

    # Dry run mode
    if [[ "${DRY_RUN}" == true ]]; then
        preview_execution "${specs[@]}"
        exit 0
    fi

    # Execute
    print_header
    log_info "🚀 並列実行を開始します"
    log_info "対象 SPEC: ${#specs[@]} 件"
    log_info "最大並列数: ${MAX_PARALLEL}"
    echo ""

    setup_tmux_session "${specs[@]}"

    log_success "すべての並列実行がキューされました"
    log_info "ログディレクトリ: ${LOG_DIR}"
}

# ============================================================================
# Entry Point
# ============================================================================

main "$@"
