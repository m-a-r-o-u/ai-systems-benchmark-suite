#!/usr/bin/env bash

# bump_slurm_job_prio.sh
#
# Raise a pending Slurm job's priority above all currently pending jobs.
#
# Usage:
#   bump_slurm_job_prio.sh JOB_ID [--offset N] [--dry-run]
#
# Options:
#   JOB_ID        Job whose priority should be raised
#   --offset N    Amount above the current maximum priority (default: 1)
#   --dry-run     Show the intended change without applying it
#   -h, --help    Show this help
#
# Requires permission to run:
#   scontrol update JobId=<JOB_ID> Priority=<N>

set -euo pipefail

OFFSET=1
DRY_RUN=false
TARGET_JOB=""

usage() {
    cat <<EOF
Usage: $(basename "$0") JOB_ID [--offset N] [--dry-run]

Options:
  --offset N    Amount above current maximum priority (default: 1)
  --dry-run     Show what would be done without changing anything
  -h, --help    Show this help
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# Argument parsing
while (($#)); do
    case "$1" in
        --offset)
            [[ $# -ge 2 ]] || die "--offset requires a value"
            OFFSET="$2"
            shift 2
            ;;
        --offset=*)
            OFFSET="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$TARGET_JOB" ]] || die "Unexpected argument: $1"
            TARGET_JOB="$1"
            shift
            ;;
    esac
done

[[ -n "$TARGET_JOB" ]] || {
    usage
    exit 1
}

[[ "$OFFSET" =~ ^[1-9][0-9]*$ ]] ||
    die "--offset must be a positive integer"

command -v scontrol >/dev/null || die "scontrol not found"
command -v squeue   >/dev/null || die "squeue not found"

# Get and validate target job
if ! JOB_INFO=$(scontrol show job -o "$TARGET_JOB" 2>/dev/null); then
    die "Job $TARGET_JOB not found or not visible"
fi

if [[ "$JOB_INFO" =~ JobState=([^[:space:]]+) ]]; then
    JOB_STATE="${BASH_REMATCH[1]}"
else
    die "Could not determine state of job $TARGET_JOB"
fi

[[ "$JOB_STATE" == "PENDING" ]] ||
    die "Job $TARGET_JOB is $JOB_STATE, not PENDING"

# Current priority of target job
CURRENT=$(
    squeue -h -j "$TARGET_JOB" -o "%Q" |
        awk 'NF { print $1; exit }'
)

[[ "$CURRENT" =~ ^[0-9]+$ ]] ||
    die "Could not determine current priority of job $TARGET_JOB"

# Find highest pending-job priority.
# awk avoids sort|head, which can interact badly with `set -o pipefail`.
HIGHEST=$(
    squeue -h -t PD -o "%Q" |
        awk '
            /^[[:space:]]*[0-9]+[[:space:]]*$/ {
                if ($1 > max)
                    max = $1
            }
            END {
                print max + 0
            }
        '
)

NEW_PRIORITY=$((HIGHEST + OFFSET))

printf '%-38s %s\n' "Highest pending-job priority:" "$HIGHEST"
printf '%-38s %s\n' "Job $TARGET_JOB current priority:" "$CURRENT"
printf '%-38s %s\n' "New priority:" "$NEW_PRIORITY"

if $DRY_RUN; then
    printf '\n[dry-run] Would run:\n'
    printf 'scontrol update JobId=%q Priority=%q\n' \
        "$TARGET_JOB" "$NEW_PRIORITY"
    exit 0
fi

scontrol update \
    JobId="$TARGET_JOB" \
    Priority="$NEW_PRIORITY"

# Verify
UPDATED=$(
    squeue -h -j "$TARGET_JOB" -o "%Q" |
        awk 'NF { print $1; exit }'
)

if [[ "$UPDATED" == "$NEW_PRIORITY" ]]; then
    printf '\nJob %s priority changed: %s -> %s\n' \
        "$TARGET_JOB" "$CURRENT" "$UPDATED"
else
    printf '\nWarning: requested priority %s, current priority is %s\n' \
        "$NEW_PRIORITY" "${UPDATED:-unknown}" >&2
fi
