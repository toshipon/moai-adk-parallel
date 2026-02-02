#!/bin/bash

# ============================================================================
# MoAI Parallel Monitor
#
# 並列実行中の SPEC のステータスを監視・表示
#
# Usage:
#   ./scripts/moai-monitor.sh [options]
#
# Options:
#   -w, --watch            リアルタイム監視モード (5秒ごと更新)
#   -l, --logs             最新ログを表示
#   -s, --summary          完了サマリーのみ表示
#   -h, --help             ヘルプ表示
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/.moai/logs/parallel"
SPECS_DIR="${PROJECT_ROOT}/.moai/specs"
TMUX_SESSION="moai-parallel"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    clear
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}  MoAI Parallel Monitor - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
}

get_spec_status() {
    local spec_name="$1"
    local spec_file="${SPECS_DIR}/${spec_name}/spec.md"

    if [[ -f "${spec_file}" ]]; then
        grep -E "^status:" "${spec_file}" 2>/dev/null | sed 's/status:[[:space:]]*//' | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

get_log_status() {
    local spec_name="$1"
    local latest_log=$(ls -t "${LOG_DIR}/${spec_name}-"*.log 2>/dev/null | head -1)

    if [[ -z "${latest_log}" ]]; then
        echo "no_log"
        return
    fi

    # 1. 完了判定: May the Force be with you が含まれていれば完了
    if grep -q "May the Force be with you" "${latest_log}" 2>/dev/null; then
        echo "success"
        return
    fi

    # 2. PR作成完了のマーカーを検索
    if grep -q "PR 作成完了\|PR作成完了\|pull request.*created" "${latest_log}" 2>/dev/null; then
        echo "success"
        return
    fi

    # 3. 完了マーカーがない場合は、まだ実行中とみなす
    # （ビルドエラーやMCPエラーは一時的な問題の可能性があり、セッションは継続中）
    if [[ -s "${latest_log}" ]]; then
        echo "running"
    else
        echo "pending"
    fi
}

show_status() {
    print_header

    # tmux セッション確認
    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        echo -e "${GREEN}✓ tmux セッション '${TMUX_SESSION}' が実行中${NC}"
        echo ""

        # ウィンドウ一覧
        echo -e "${BLUE}┌─────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}│ 実行中のウィンドウ                                              │${NC}"
        echo -e "${BLUE}├─────────────────────────────────────────────────────────────────┤${NC}"

        tmux list-windows -t "${TMUX_SESSION}" -F "│ #{window_index}: #{window_name}" | while read line; do
            echo -e "${BLUE}${line}${NC}"
        done

        echo -e "${BLUE}└─────────────────────────────────────────────────────────────────┘${NC}"
    else
        echo -e "${YELLOW}⚠ tmux セッション '${TMUX_SESSION}' が見つかりません${NC}"
    fi

    echo ""

    # SPEC ステータス
    echo -e "${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│ SPEC ステータス                                                 │${NC}"
    echo -e "${GREEN}├─────────────────────────────────────────────────────────────────┤${NC}"

    local completed=0
    local running=0
    local error=0
    local pending=0

    for log_file in "${LOG_DIR}"/SPEC-*.log; do
        if [[ ! -f "${log_file}" ]]; then
            continue
        fi

        local spec_name=$(basename "${log_file}" | sed 's/-[0-9].*\.log$//')
        local spec_status=$(get_spec_status "${spec_name}")
        local log_status=$(get_log_status "${spec_name}")

        local status_icon=""
        local status_color=""

        case "${log_status}" in
            success)
                status_icon="✅"
                status_color="${GREEN}"
                ((completed++))
                ;;
            error)
                status_icon="❌"
                status_color="${RED}"
                ((error++))
                ;;
            running)
                status_icon="🔄"
                status_color="${YELLOW}"
                ((running++))
                ;;
            *)
                status_icon="⏳"
                status_color="${GRAY}"
                ((pending++))
                ;;
        esac

        echo -e "${GREEN}│${NC} ${status_icon} ${spec_name}"
        echo -e "${GREEN}│${NC}    └─ SPEC: ${spec_status} / Log: ${status_color}${log_status}${NC}"
    done

    echo -e "${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    # サマリー
    echo -e "${CYAN}サマリー: ✅ ${completed} 完了 | 🔄 ${running} 実行中 | ❌ ${error} エラー | ⏳ ${pending} 待機${NC}"
    echo ""
}

show_logs() {
    echo -e "${BLUE}最新ログファイル:${NC}"
    echo ""

    ls -lt "${LOG_DIR}"/SPEC-*.log 2>/dev/null | head -10 | while read line; do
        echo "  ${line}"
    done

    echo ""
    echo -e "${GRAY}ログを確認するには: tail -f ${LOG_DIR}/<SPEC-NAME>-<timestamp>.log${NC}"
}

show_summary() {
    local completed=0
    local total=0

    for spec_dir in "${SPECS_DIR}"/SPEC-*; do
        if [[ -d "${spec_dir}" ]]; then
            ((total++))
            local status=$(get_spec_status "$(basename "${spec_dir}")")
            if [[ "${status}" == "completed" ]]; then
                ((completed++))
            fi
        fi
    done

    echo ""
    echo -e "${CYAN}SPEC 完了状況: ${completed}/${total} ($(( completed * 100 / total ))%)${NC}"
    echo ""
}

watch_mode() {
    while true; do
        show_status
        echo -e "${GRAY}(5秒ごとに更新中... Ctrl+C で終了)${NC}"
        sleep 5
    done
}

show_help() {
    cat << EOF
MoAI Parallel Monitor - 並列実行ステータス監視

Usage: $0 [options]

Options:
  -w, --watch            リアルタイム監視モード (5秒ごと更新)
  -l, --logs             最新ログファイル一覧
  -s, --summary          完了サマリーのみ表示
  -h, --help             このヘルプを表示

Examples:
  $0                     # 現在のステータス表示
  $0 --watch             # リアルタイム監視
  $0 --logs              # ログファイル一覧

tmux 操作:
  tmux attach -t moai-parallel       # セッションにアタッチ
  Ctrl+b n                           # 次のウィンドウ
  Ctrl+b p                           # 前のウィンドウ
  Ctrl+b d                           # デタッチ

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    case "${1:-}" in
        -w|--watch)
            watch_mode
            ;;
        -l|--logs)
            show_logs
            ;;
        -s|--summary)
            show_summary
            ;;
        -h|--help)
            show_help
            ;;
        *)
            show_status
            ;;
    esac
}

main "$@"
