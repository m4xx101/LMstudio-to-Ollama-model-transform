#!/usr/bin/env bash
#
# sync-local-models.sh
#
# Sync LM Studio GGUF models to other local inference tools without
# duplicating files. Works on macOS (bash 3.2+) and Linux.
#
# Supported targets:
#   ollama                 creates a Modelfile + runs `ollama create`
#   text-generation-webui  hardlinks GGUF into user_data/models
#   koboldcpp              generates per-model launcher script
#   llamacpp-server        generates per-model launcher script
#   jan                    hardlinks GGUF into Jan's llamacpp/models folder
#
# By default every target uses hardlinks or absolute-path references so
# a multi-GB GGUF is never duplicated on disk.
#
# Modelfiles generated for Ollama are DELIBERATELY MINIMAL so Ollama's
# own GGUF metadata template detection can work. Hardcoding a generic
# ChatML template (as the original script did) breaks Llama 3, Mistral,
# Gemma, DeepSeek, Phi and Qwen models. Use --ollama-template to override.
#
# Author: m4xx (Deepak Mistry)
# License: MIT

# Don't use `set -e` — we want one bad model to be logged and skipped,
# not to abort the whole run.
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SOURCE_DIR="${HOME}/.lmstudio/models"
TARGETS_DEFAULT="ollama"
TARGETS=""
OLLAMA_CATALOG="${HOME}/.ollama/custom-models"
TEXTGEN_MODELS_DIR=""
KOBOLDCPP_EXE=""
LLAMACPP_DIR=""

# Jan default data directory per OS
case "$(uname -s)" in
    Darwin) JAN_DATA_DIR="${HOME}/Library/Application Support/Jan/data" ;;
    *)      JAN_DATA_DIR="${HOME}/jan/data" ;;
esac

LAUNCH_SCRIPT_DIR="${HOME}/local-models-launch"
NAME_PREFIX=""
INCLUDE_FILTER=""
EXCLUDE_FILTER='(mmproj|mm-proj)|\.(downloading|incomplete|partial)$'
OLLAMA_TEMPLATE=""
FORCE=0
DRY_RUN=0
LOG_PATH="${TMPDIR:-/tmp}/sync-local-models-$(date +%Y%m%d-%H%M%S).log"

# Stats (using simple vars since bash 3.2 has no associative arrays)
STAT_DISCOVERED=0
STAT_REGISTERED=0
STAT_SKIPPED=0
STAT_FAILED=0

# ---------------------------------------------------------------------------
# Terminal colors (only when stdout is a TTY)
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    C_RESET="$(tput sgr0    2>/dev/null || printf '')"
    C_RED="$(tput setaf 1   2>/dev/null || printf '')"
    C_GREEN="$(tput setaf 2 2>/dev/null || printf '')"
    C_YELLOW="$(tput setaf 3 2>/dev/null || printf '')"
    C_BLUE="$(tput setaf 4  2>/dev/null || printf '')"
    C_GREY="$(tput setaf 8  2>/dev/null || printf '')"
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_GREY=""
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    # log <LEVEL> <message...>
    level="$1"; shift
    msg="$*"
    stamp="$(date '+%Y-%m-%d %H:%M:%S')"
    line="[${stamp}] [$(printf '%-5s' "${level}")] ${msg}"

    case "${level}" in
        OK)    color="${C_GREEN}" ;;
        WARN)  color="${C_YELLOW}" ;;
        ERROR) color="${C_RED}" ;;
        DEBUG) color="${C_GREY}" ;;
        *)     color="${C_BLUE}" ;;
    esac
    printf '%s%s%s\n' "${color}" "${line}" "${C_RESET}"

    # Tee to logfile; don't let write failure kill the run
    printf '%s\n' "${line}" >> "${LOG_PATH}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
show_help() {
    cat <<EOF
sync-local-models.sh — share LM Studio GGUF models with other inference tools

USAGE
  $0 [OPTIONS]

OPTIONS
  --source DIR              LM Studio model root
                            (default: \$HOME/.lmstudio/models)
  --target NAME[,NAME...]   targets: ollama, text-generation-webui,
                            koboldcpp, llamacpp-server, jan, all
                            (default: ollama)
  --ollama-catalog DIR      where generated Modelfiles are stored
                            (default: \$HOME/.ollama/custom-models)
  --textgen-models-dir DIR  text-generation-webui user_data/models folder
  --koboldcpp-exe PATH      full path to koboldcpp (binary)
  --llamacpp-dir DIR        folder containing llama-server binary
  --jan-data-dir DIR        Jan data directory
                            (macOS default: ~/Library/Application Support/Jan/data)
                            (Linux default: ~/jan/data)
  --launch-script-dir DIR   where per-model launcher scripts are written
                            (default: \$HOME/local-models-launch)
  --name-prefix STR         prepend STR to every registered model name
  --include-filter REGEX    only process GGUF paths matching REGEX
  --exclude-filter REGEX    skip GGUF paths matching REGEX
                            (default excludes mmproj + partial downloads)
  --ollama-template STR     raw TEMPLATE block for every Modelfile;
                            leave empty to rely on GGUF autodetection
  --force                   re-register models that already exist
  --dry-run                 print what would happen, change nothing
  --log-path PATH           log file (default: a timestamped file in TMPDIR)
  -h, --help                show this help

EXAMPLES
  # Dry run against Ollama only
  $0 --target ollama --dry-run

  # Ollama + text-generation-webui in one pass
  $0 --target ollama,text-generation-webui \\
     --textgen-models-dir ~/ai/textgen/user_data/models

  # Everything, with a namespace prefix, overwrite existing
  $0 --target all \\
     --textgen-models-dir ~/ai/textgen/user_data/models \\
     --koboldcpp-exe      ~/ai/koboldcpp/koboldcpp \\
     --llamacpp-dir       ~/ai/llama.cpp/build/bin \\
     --name-prefix 'lms-' --force
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing (long options, portable)
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --source)              SOURCE_DIR="$2";          shift 2 ;;
        --target)              TARGETS="$2";             shift 2 ;;
        --ollama-catalog)      OLLAMA_CATALOG="$2";      shift 2 ;;
        --textgen-models-dir)  TEXTGEN_MODELS_DIR="$2";  shift 2 ;;
        --koboldcpp-exe)       KOBOLDCPP_EXE="$2";       shift 2 ;;
        --llamacpp-dir)        LLAMACPP_DIR="$2";        shift 2 ;;
        --jan-data-dir)        JAN_DATA_DIR="$2";        shift 2 ;;
        --launch-script-dir)   LAUNCH_SCRIPT_DIR="$2";   shift 2 ;;
        --name-prefix)         NAME_PREFIX="$2";         shift 2 ;;
        --include-filter)      INCLUDE_FILTER="$2";      shift 2 ;;
        --exclude-filter)      EXCLUDE_FILTER="$2";      shift 2 ;;
        --ollama-template)     OLLAMA_TEMPLATE="$2";     shift 2 ;;
        --force)               FORCE=1;                  shift ;;
        --dry-run)             DRY_RUN=1;                shift ;;
        --log-path)            LOG_PATH="$2";            shift 2 ;;
        -h|--help)             show_help; exit 0 ;;
        *)  echo "Unknown argument: $1" >&2; echo "Use --help for usage." >&2; exit 64 ;;
    esac
done

[ -z "${TARGETS}" ] && TARGETS="${TARGETS_DEFAULT}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Lowercase using tr (portable across bash 3.2 and zsh)
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Sanitize a string into an Ollama-friendly model name.
# Allowed: [a-z0-9._-]. Collapse runs of '-'. Trim leading/trailing punct.
safe_name() {
    raw="$1"
    name="$(to_lower "${raw}")"
    name="$(printf '%s' "${name}" | sed -E 's/[^a-z0-9._-]/-/g; s/-+/-/g; s/^[-._]+//; s/[-._]+$//')"
    # Cap length
    name="$(printf '%s' "${name}" | cut -c1-120)"
    name="$(printf '%s' "${name}" | sed -E 's/[-._]+$//')"
    [ -z "${name}" ] && name="model"
    printf '%s' "${name}"
}

# Does Ollama already know about a given model name?
ollama_has_model() {
    name="$1"
    if ! command -v ollama >/dev/null 2>&1; then return 1; fi
    ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "^${name}(:.*)?$" >/dev/null 2>&1
}

# Check if two paths are on the same filesystem (device id).
# Uses `stat` with OS-specific flags.
same_filesystem() {
    src="$1"; dst_dir="$2"
    [ -d "${dst_dir}" ] || dst_dir="$(dirname "${dst_dir}")"
    case "$(uname -s)" in
        Darwin|*BSD*) src_dev="$(stat -f '%d' "${src}"     2>/dev/null || echo x)"
                      dst_dev="$(stat -f '%d' "${dst_dir}" 2>/dev/null || echo y)" ;;
        *)            src_dev="$(stat -c '%d' "${src}"     2>/dev/null || echo x)"
                      dst_dev="$(stat -c '%d' "${dst_dir}" 2>/dev/null || echo y)" ;;
    esac
    [ "${src_dev}" = "${dst_dev}" ]
}

# Create a hardlink (same fs) or symlink (cross fs) from SRC into DEST_DIR.
# Prints the new link path on success, empty on failure.
make_link() {
    src="$1"; dest_dir="$2"; new_name="$3"
    [ -z "${new_name}" ] && new_name="$(basename "${src}")"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log DEBUG "[dry-run] would link ${src} -> ${dest_dir}/${new_name}"
        printf '%s' "${dest_dir}/${new_name}"
        return 0
    fi

    mkdir -p "${dest_dir}" 2>/dev/null || {
        log ERROR "Cannot create directory: ${dest_dir}"
        return 1
    }

    dest="${dest_dir}/${new_name}"

    if [ -e "${dest}" ] || [ -L "${dest}" ]; then
        if [ "${FORCE}" -eq 1 ]; then
            rm -f "${dest}" 2>/dev/null
        else
            log DEBUG "Link/file already present: ${dest} (use --force to replace)"
            printf '%s' "${dest}"
            return 0
        fi
    fi

    if same_filesystem "${src}" "${dest_dir}"; then
        # Hardlink — zero storage, behaves as a normal file
        if ln "${src}" "${dest}" 2>/dev/null; then
            log DEBUG "Hardlinked -> ${dest}"
            printf '%s' "${dest}"
            return 0
        fi
        log WARN "Hardlink failed, falling back to symlink"
    fi

    if ln -s "${src}" "${dest}" 2>/dev/null; then
        log DEBUG "Symlinked -> ${dest}"
        printf '%s' "${dest}"
        return 0
    fi

    log ERROR "Failed to link ${src} -> ${dest}"
    return 1
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prereqs() {
    ok=1

    if [ ! -d "${SOURCE_DIR}" ]; then
        log ERROR "Source directory not found: ${SOURCE_DIR}"
        return 1
    fi
    log OK "Source OK: ${SOURCE_DIR}"

    # Expand 'all'
    effective="${TARGETS}"
    case ",${TARGETS}," in
        *,all,*) effective="ollama,text-generation-webui,koboldcpp,llamacpp-server,jan" ;;
    esac

    # Iterate
    old_ifs="${IFS}"; IFS=,
    for t in ${effective}; do
        IFS="${old_ifs}"
        case "${t}" in
            ollama)
                if ! command -v ollama >/dev/null 2>&1; then
                    log ERROR "Ollama not found in PATH. Install from https://ollama.com or remove 'ollama' from --target."
                    ok=0
                else
                    log OK "Ollama found: $(command -v ollama)"
                fi ;;
            text-generation-webui)
                if [ -z "${TEXTGEN_MODELS_DIR}" ]; then
                    log ERROR "text-generation-webui target needs --textgen-models-dir"
                    ok=0
                elif [ ! -d "${TEXTGEN_MODELS_DIR}" ]; then
                    log WARN "TEXTGEN_MODELS_DIR does not exist: ${TEXTGEN_MODELS_DIR} (will be created)"
                fi ;;
            koboldcpp)
                if [ -z "${KOBOLDCPP_EXE}" ]; then
                    log ERROR "koboldcpp target needs --koboldcpp-exe"; ok=0
                elif [ ! -x "${KOBOLDCPP_EXE}" ]; then
                    log ERROR "koboldcpp binary not executable: ${KOBOLDCPP_EXE}"; ok=0
                fi ;;
            llamacpp-server)
                if [ -z "${LLAMACPP_DIR}" ]; then
                    log ERROR "llamacpp-server target needs --llamacpp-dir"; ok=0
                elif [ ! -x "${LLAMACPP_DIR}/llama-server" ]; then
                    log ERROR "llama-server not found or not executable: ${LLAMACPP_DIR}/llama-server"; ok=0
                fi ;;
            jan)
                jan_models="${JAN_DATA_DIR}/llamacpp/models"
                if [ ! -d "${jan_models}" ]; then
                    log WARN "Jan models folder ${jan_models} does not exist (will be created). Launch Jan at least once first."
                fi ;;
            *) log ERROR "Unknown target: ${t}"; ok=0 ;;
        esac
        IFS=,
    done
    IFS="${old_ifs}"

    [ "${ok}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Model discovery (writes results to a temp file, one per line:
#   fullpath|basename|publisher|modeldir|size_bytes
# )
# ---------------------------------------------------------------------------
discover_models() {
    out_file="$1"
    : > "${out_file}"

    log INFO "Scanning for GGUF files under ${SOURCE_DIR} ..."
    # find works on both macOS and Linux; -print0/null-read handles spaces.
    find "${SOURCE_DIR}" -type f -name '*.gguf' -print0 2>/dev/null |
    while IFS= read -r -d '' full; do
        # Include filter
        if [ -n "${INCLUDE_FILTER}" ]; then
            if ! printf '%s' "${full}" | grep -Eq "${INCLUDE_FILTER}"; then
                continue
            fi
        fi
        # Exclude filter
        if [ -n "${EXCLUDE_FILTER}" ]; then
            if printf '%s' "${full}" | grep -Eq "${EXCLUDE_FILTER}"; then
                log DEBUG "Skip (exclude-filter): $(basename "${full}")"
                continue
            fi
        fi

        fname="$(basename "${full}")"

        # Multi-part GGUFs: only first shard (00001-of-000NN).
        split_idx="$(printf '%s' "${fname}" | sed -nE 's/.*-([0-9]{5})-of-[0-9]{5}\.gguf$/\1/p')"
        if [ -n "${split_idx}" ] && [ "${split_idx}" != "00001" ]; then
            log DEBUG "Skip (non-first split): ${fname}"
            continue
        fi

        # Logical layout: <source>/<publisher>/<model>/<file>.gguf
        rel="${full#${SOURCE_DIR}/}"
        publisher=""
        modeldir=""
        case "${rel}" in
            */*/*)
                publisher="${rel%%/*}"
                rest="${rel#*/}"
                modeldir="${rest%%/*}" ;;
            *)
                modeldir="${fname%.gguf}" ;;
        esac

        base="${fname%.gguf}"
        size="$(wc -c < "${full}" 2>/dev/null | tr -d ' ' || echo 0)"

        printf '%s|%s|%s|%s|%s\n' "${full}" "${base}" "${publisher}" "${modeldir}" "${size}" >> "${out_file}"
    done

    count="$(wc -l < "${out_file}" | tr -d ' ')"
    log OK "Discovery complete. ${count} candidate GGUF file(s)."
}

# ---------------------------------------------------------------------------
# Target: Ollama
# ---------------------------------------------------------------------------
register_ollama() {
    full="$1"; base="$2"
    name="$(safe_name "${NAME_PREFIX}${base}")"

    if ollama_has_model "${name}" && [ "${FORCE}" -eq 0 ]; then
        log WARN "Ollama already has '${name}' — skip"
        STAT_SKIPPED=$((STAT_SKIPPED + 1))
        return 0
    fi

    mkdir -p "${OLLAMA_CATALOG}" 2>/dev/null
    mf="${OLLAMA_CATALOG}/${name}.Modelfile"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log INFO "[dry-run] would write ${mf} and run: ollama create ${name} -f ${mf}"
        return 0
    fi

    {
        printf '# Auto-generated %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
        printf '# Source: %s\n' "${full}"
        printf 'FROM "%s"\n' "${full}"
        printf 'PARAMETER temperature 0.7\n'
        printf 'PARAMETER top_p 0.9\n'
        printf 'PARAMETER repeat_penalty 1.1\n'
        if [ -n "${OLLAMA_TEMPLATE}" ]; then
            printf '\nTEMPLATE """%s"""\n' "${OLLAMA_TEMPLATE}"
        fi
    } > "${mf}"

    if ollama create "${name}" -f "${mf}" >/tmp/ollama-create.out 2>&1; then
        log OK "Ollama registered: ${name}"
        STAT_REGISTERED=$((STAT_REGISTERED + 1))
    else
        log ERROR "ollama create '${name}' failed. Output:"
        while IFS= read -r line; do log ERROR "  ${line}"; done < /tmp/ollama-create.out
        STAT_FAILED=$((STAT_FAILED + 1))
    fi
    rm -f /tmp/ollama-create.out
}

# ---------------------------------------------------------------------------
# Target: text-generation-webui
# ---------------------------------------------------------------------------
register_textgen() {
    full="$1"; fname="$(basename "${full}")"
    link_name="${NAME_PREFIX}${fname}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log INFO "[dry-run] would link into ${TEXTGEN_MODELS_DIR}/${link_name}"
        return 0
    fi

    if dest="$(make_link "${full}" "${TEXTGEN_MODELS_DIR}" "${link_name}")" && [ -n "${dest}" ]; then
        log OK "text-generation-webui: ${link_name}"
        STAT_REGISTERED=$((STAT_REGISTERED + 1))
    else
        STAT_FAILED=$((STAT_FAILED + 1))
    fi
}

# ---------------------------------------------------------------------------
# Target: Jan
# ---------------------------------------------------------------------------
register_jan() {
    full="$1"; modeldir="$2"
    jan_models="${JAN_DATA_DIR}/llamacpp/models"
    folder_name="$(safe_name "${NAME_PREFIX}${modeldir}")"
    target_dir="${jan_models}/${folder_name}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log INFO "[dry-run] would link GGUF into ${target_dir}"
        return 0
    fi

    if dest="$(make_link "${full}" "${target_dir}" "$(basename "${full}")")" && [ -n "${dest}" ]; then
        {
            printf 'Model linked by sync-local-models.sh on %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
            printf 'Source: %s\n\n' "${full}"
            printf 'In Jan: Settings -> Model Providers -> llama.cpp -> Import\n'
            printf 'and point at %s (or restart Jan — it scans this folder).\n' "${dest}"
        } > "${target_dir}/README-synced.txt"
        log OK "Jan: ${folder_name}"
        STAT_REGISTERED=$((STAT_REGISTERED + 1))
    else
        STAT_FAILED=$((STAT_FAILED + 1))
    fi
}

# ---------------------------------------------------------------------------
# Targets: launcher scripts for koboldcpp / llamacpp-server
# ---------------------------------------------------------------------------
write_launcher() {
    full="$1"; base="$2"; kind="$3"
    safe="$(safe_name "${NAME_PREFIX}${base}")"
    script="${LAUNCH_SCRIPT_DIR}/${kind}-${safe}.sh"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log INFO "[dry-run] would write launcher ${script}"
        return 0
    fi

    mkdir -p "${LAUNCH_SCRIPT_DIR}" 2>/dev/null

    if [ -f "${script}" ] && [ "${FORCE}" -eq 0 ]; then
        log DEBUG "${kind} launcher exists: ${script} (use --force to overwrite)"
        STAT_SKIPPED=$((STAT_SKIPPED + 1))
        return 0
    fi

    case "${kind}" in
        koboldcpp)
            {
                printf '#!/usr/bin/env bash\n'
                printf '# Auto-generated launcher for %s\n' "$(basename "${full}")"
                printf '# Generated %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
                printf 'exec "%s" --model "%s" --gpulayers 999 --contextsize 8192 "$@"\n' \
                    "${KOBOLDCPP_EXE}" "${full}"
            } > "${script}"
            ;;
        llamacpp-server)
            srv="${LLAMACPP_DIR}/llama-server"
            {
                printf '#!/usr/bin/env bash\n'
                printf '# Auto-generated launcher for %s\n' "$(basename "${full}")"
                printf '# Generated %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
                printf 'exec "%s" -m "%s" -c 8192 -ngl 999 --host 127.0.0.1 --port 8080 "$@"\n' \
                    "${srv}" "${full}"
            } > "${script}"
            ;;
    esac

    chmod +x "${script}" 2>/dev/null
    log OK "${kind} launcher: ${script}"
    STAT_REGISTERED=$((STAT_REGISTERED + 1))
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
run_sync() {
    # Expand 'all'
    effective="${TARGETS}"
    case ",${TARGETS}," in
        *,all,*) effective="ollama,text-generation-webui,koboldcpp,llamacpp-server,jan" ;;
    esac

    # Filter to only configured ones
    filtered=""
    old_ifs="${IFS}"; IFS=,
    for t in ${effective}; do
        IFS="${old_ifs}"
        keep=0
        case "${t}" in
            ollama)                keep=1 ;;
            text-generation-webui) [ -n "${TEXTGEN_MODELS_DIR}" ] && keep=1 ;;
            koboldcpp)             [ -n "${KOBOLDCPP_EXE}" ]      && keep=1 ;;
            llamacpp-server)       [ -n "${LLAMACPP_DIR}" ]       && keep=1 ;;
            jan)                   keep=1 ;;
        esac
        if [ "${keep}" -eq 1 ]; then
            if [ -z "${filtered}" ]; then filtered="${t}"; else filtered="${filtered},${t}"; fi
        fi
        IFS=,
    done
    IFS="${old_ifs}"

    log INFO "Active targets: ${filtered}"

    tmp_models="$(mktemp "${TMPDIR:-/tmp}/syncmodels.XXXXXX")"
    trap 'rm -f "${tmp_models}"' EXIT

    discover_models "${tmp_models}"
    STAT_DISCOVERED="$(wc -l < "${tmp_models}" | tr -d ' ')"

    if [ "${STAT_DISCOVERED}" -eq 0 ]; then
        log WARN "No GGUF models found."
        return
    fi

    i=0
    while IFS='|' read -r full base publisher modeldir size; do
        i=$((i + 1))
        size_mb=$(( size / 1048576 ))
        log INFO "[${i}/${STAT_DISCOVERED}] $(basename "${full}")  (${size_mb} MiB)"

        old_ifs="${IFS}"; IFS=,
        for t in ${filtered}; do
            IFS="${old_ifs}"
            # Wrap each target call so a failure is logged but doesn't abort
            (
                case "${t}" in
                    ollama)                register_ollama   "${full}" "${base}" ;;
                    text-generation-webui) register_textgen  "${full}" ;;
                    koboldcpp)             write_launcher    "${full}" "${base}" koboldcpp ;;
                    llamacpp-server)       write_launcher    "${full}" "${base}" llamacpp-server ;;
                    jan)                   register_jan      "${full}" "${modeldir}" ;;
                esac
            ) || true
            IFS=,
        done
        IFS="${old_ifs}"
    done < "${tmp_models}"

    # Subshells above broke stat inheritance; re-count registrations from log
    # for an accurate summary. (A pragmatic workaround for POSIX sh scoping.)
    # Use `grep | wc -l` rather than `grep -c` so a zero count is always a
    # single number even when the fallback fires.
    STAT_REGISTERED=$(grep -E '\[OK   \] (Ollama registered|text-generation-webui:|Jan:|koboldcpp launcher|llamacpp-server launcher)' "${LOG_PATH}" 2>/dev/null | wc -l | tr -d ' ')
    STAT_SKIPPED=$(   grep -E '\[WARN \] .* already has'                                                           "${LOG_PATH}" 2>/dev/null | wc -l | tr -d ' ')
    STAT_FAILED=$(    grep -E '\[ERROR\] (ollama create|Failed to link)'                                           "${LOG_PATH}" 2>/dev/null | wc -l | tr -d ' ')
}

print_summary() {
    echo
    log INFO "============================================================"
    log INFO "SUMMARY"
    log INFO "------------------------------------------------------------"
    log INFO "GGUF files discovered: ${STAT_DISCOVERED}"
    log OK   "Total registered:      ${STAT_REGISTERED}"
    log WARN "Total skipped:         ${STAT_SKIPPED}"
    if [ "${STAT_FAILED}" -gt 0 ]; then
        log ERROR "Total failed:          ${STAT_FAILED}"
    else
        log OK   "Total failed:          0"
    fi
    log INFO "============================================================"
    log INFO "Log written to: ${LOG_PATH}"
}

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
log INFO "sync-local-models starting (pid $$)"
log INFO "$(uname -a)"
[ "${DRY_RUN}" -eq 1 ] && log WARN "DRY RUN — no changes will be made"

if ! check_prereqs; then
    log ERROR "Prerequisite check failed. Aborting."
    print_summary
    exit 1
fi

run_sync
print_summary
[ "${STAT_FAILED}" -gt 0 ] && exit 1 || exit 0
