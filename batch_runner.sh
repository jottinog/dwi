# This is the batch runner for dwi_step2_process.sh

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_ONE="$SCRIPT_DIR/dwi_step2_process_v6.sh"       # modify here to match script name
 
LOGDIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGDIR"

SUCCESS="$LOGDIR/success.txt"
FAIL="$LOGDIR/fail.txt"

# ensure lists exist but NEVER truncate
touch "$SUCCESS" "$FAIL"

COUNT=0
BATCH_SIZE=27

for s in "$SCRIPT_DIR"/sub_*; do
  [ -d "$s" ] || continue
  subj=$(basename "$s")
  log="$LOGDIR/${subj}.log"

  # ------------------------------------------------------------
  # Skip subjects already marked successful
  # ------------------------------------------------------------
  if grep -qx "$subj" "$SUCCESS"; then
    echo "⏭ $subj already successful — skipping"
    continue
  fi
  # ------------------------------------------------------------

  COUNT=$((COUNT + 1))
  echo "▶▶▶ [$COUNT] $subj"

  if script -q "$log" "$RUN_ONE" "$subj"; then
    echo "✅ $subj done"
    echo "$subj" >> "$SUCCESS"
  else
    echo "❌ $subj failed"
    echo "$subj" >> "$FAIL"
  fi

  # flush IO + cooldown between subjects (optional but safe)
  sync
  sleep 20

  # stop cleanly after each batch
  if [ $((COUNT % BATCH_SIZE)) -eq 0 ]; then
    echo
    echo "🛑 Batch of $BATCH_SIZE finished — exiting safely"
    echo "👉 Resume by re-running ./batch_runner.sh"
    exit 0
  fi
done

echo
echo "🎉 All subjects processed"
echo "✅ Success: $(wc -l < "$SUCCESS")"
echo "❌ Failed:  $(wc -l < "$FAIL")"
