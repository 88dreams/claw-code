#!/bin/bash
# Discord → Agent dispatch script
# Called by OpenClaw to spawn agent sessions via opencode/tmux
# Usage: discord-dispatch.sh <mode> <task> [channel_id]

# Ensure cargo/local bins are in PATH (needed when called from OpenClaw subprocess)
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

MODE="$1"
TASK="$2"
CHANNEL="${3:-1492050822681595935}"
WORKDIR="$HOME/claw-code"
# Default LLM used for opencode-dispatched roles unless a branch overrides it.
MODEL="openrouter/google/gemini-3.1-pro-preview"

cd "$WORKDIR" || exit 1

notify() {
    clawhip send --channel "$CHANNEL" --message "$1" 2>/dev/null || true
}

# Clear stale OmX session state that can block or confuse new omx exec runs.
# Called before every OmX dispatch to prevent session collisions.
clean_omx_state() {
    rm -f "$WORKDIR/.omx/state/team-state.json" 2>/dev/null
    rm -f "$WORKDIR/.omx/state/native-stop-state.json" 2>/dev/null
    rm -f "$WORKDIR/.omx/state/session.json" 2>/dev/null
    rm -f "$WORKDIR/.omx/state/dispatch.json" 2>/dev/null
}

# Send long agent output to a role channel. Discord caps messages at 2000 chars,
# so truncate with a marker. Full output still goes to stdout for programmatic
# callers. Returns non-zero if the clawhip send fails, so callers (including
# pipeline mode) can detect silent DLQ drops.
#   $1 = target channel ID
#   $2 = label (e.g. "Architect Output")
#   $3 = full output text
send_role_output() {
    local CHANNEL_ID="$1"
    local LABEL="$2"
    local FULL="$3"
    local HEADER="**${LABEL}:**"
    # Discord limit is 2000. Budget: header (~30), truncation marker (~35),
    # newlines (~5). Leaves ~1900 for actual content. Round down for safety.
    local MAX_BODY=1900
    local BODY
    if [ ${#FULL} -gt $MAX_BODY ]; then
        # Keep the TAIL of the output, not the head. The orchestrator's
        # delegation narration comes first; the sub-agent's actual findings
        # come last. Front-truncation would drop the valuable part.
        BODY=$'… [earlier output truncated]\n'"${FULL: -$MAX_BODY}"
    else
        BODY="$FULL"
    fi
    if ! clawhip send --channel "$CHANNEL_ID" --message "${HEADER}
${BODY}"; then
        echo "ERROR: clawhip send to channel $CHANNEL_ID failed (${LABEL})" >&2
        return 1
    fi
    return 0
}

case "$MODE" in
    team)
        SESSION_NAME="omx-team-$(date +%s)"
        notify "Spawning \$team session: $SESSION_NAME"

        # Kill any existing omx team state
        rm -f "$WORKDIR/.omx/state/team-state.json" 2>/dev/null
        rm -rf "$WORKDIR/.omx/state/team/" 2>/dev/null

        # Create tmux session and run omx team
        tmux new-session -d -s "$SESSION_NAME" -c "$WORKDIR" \
            "omx team \"$TASK\" 2>&1; clawhip send --channel $CHANNEL --message 'Team session $SESSION_NAME completed.'; sleep 5"

        notify "Team session $SESSION_NAME started in tmux. Agents are working."
        echo "tmux_session=$SESSION_NAME"
        ;;

    architect)
        ARCHITECT_MODE="${ARCHITECT_MODE:-opencode}"
        if [ "$ARCHITECT_MODE" = "omx" ]; then
            notify "Dispatching \$architect via OmX (gpt-5.4, read-only analysis)..."
            clean_omx_state
            OUTPUT=$(cd "$WORKDIR" && omx exec --dangerously-bypass-approvals-and-sandbox --ephemeral \
                "You are Architect. You are READ-ONLY — never edit files. Analyze with file-backed evidence, cite file:line references, identify root causes, and provide concrete recommendations with tradeoffs. Task: $TASK" 2>&1 | tail -400)
        else
            notify "Dispatching \$architect via opencode (Gemini 3.1 Pro)..."
            OUTPUT=$(opencode run -m "$MODEL" --dir "$WORKDIR" --dangerously-skip-permissions \
                "You MUST delegate the following task to the Architect sub-agent SYNCHRONOUSLY — do NOT launch it in the background. Wait for the sub-agent to finish, then include its COMPLETE output in your final response. Do not summarize or paraphrase — paste the sub-agent's full text. Do not respond until the sub-agent has returned. Task: $TASK" 2>&1 | tail -400)
        fi
        echo "$OUTPUT"
        send_role_output 1493722920491552889 "Architect Output" "$OUTPUT" || exit 1
        ;;

    executor)
        EXECUTOR_MODE="${EXECUTOR_MODE:-opencode}"
        if [ "$EXECUTOR_MODE" = "omx" ]; then
            notify "Dispatching \$executor via OmX (gpt-5.4, Lore commits enabled)..."
            clean_omx_state
            OUTPUT=$(cd "$WORKDIR" && omx exec --dangerously-bypass-approvals-and-sandbox --ephemeral \
                "$TASK" 2>&1 | tail -400)
        else
            notify "Dispatching \$executor via opencode (Gemini 3.1 Pro)..."
            OUTPUT=$(opencode run -m "$MODEL" --dir "$WORKDIR" --dangerously-skip-permissions \
                "You MUST delegate the following task to the Executor sub-agent SYNCHRONOUSLY — do NOT launch it in the background. Wait for the sub-agent to finish, then include its COMPLETE output in your final response. Do not summarize or paraphrase — paste the sub-agent's full text. Do not respond until the sub-agent has returned. Task: $TASK" 2>&1 | tail -400)
        fi
        echo "$OUTPUT"
        send_role_output 1493722957992689744 "Executor Output" "$OUTPUT" || exit 1
        ;;

    arch-omx)
        # Direct OmX architect keyword for A/B testing.
        ARCHITECT_MODE=omx exec "$0" architect "$TASK" "$CHANNEL"
        ;;

    exec-omx)
        # Direct OmX executor keyword for A/B testing.
        EXECUTOR_MODE=omx exec "$0" executor "$TASK" "$CHANNEL"
        ;;

    review-omx)
        # Direct OmX reviewer keyword for A/B testing.
        REVIEWER_MODE=omx exec "$0" reviewer "$TASK" "$CHANNEL"
        ;;

    reviewer)
        REVIEWER_MODE="${REVIEWER_MODE:-opencode}"
        if [ "$REVIEWER_MODE" = "omx" ]; then
            notify "Dispatching \$reviewer via OmX (gpt-5.4, two-stage review)..."
            clean_omx_state
            OUTPUT=$(cd "$WORKDIR" && omx exec --dangerously-bypass-approvals-and-sandbox --ephemeral \
                "You are Code Reviewer. Perform a two-stage review: Stage 1 (spec compliance) then Stage 2 (code quality with lsp_diagnostics). Rate each issue by severity (CRITICAL/HIGH/MEDIUM/LOW). Your response MUST end with a single verdict line in exactly this format: Verdict: APPROVE or Verdict: REQUEST CHANGES or Verdict: COMMENT — this line is machine-parsed by the pipeline gate. Task: $TASK" 2>&1 | tail -400)
        else
            notify "Dispatching \$reviewer via opencode (Gemini 3.1 Pro)..."
            OUTPUT=$(opencode run -m "$MODEL" --dir "$WORKDIR" --dangerously-skip-permissions \
                "You MUST delegate the following task to the Code Reviewer sub-agent SYNCHRONOUSLY — do NOT launch it in the background. Wait for the sub-agent to finish, then include its COMPLETE output in your final response. Do not summarize or paraphrase — paste the sub-agent's full text. Do not respond until the sub-agent has returned. Task: $TASK" 2>&1 | tail -400)
        fi
        echo "$OUTPUT"
        send_role_output 1493722988732874763 "Reviewer Output" "$OUTPUT" || exit 1
        ;;

    claw)
        notify "Dispatching to claw-code (Claude)..."
        OUTPUT=$(cd "$WORKDIR" && ./rust/target/debug/claw prompt "$TASK" 2>&1 | tail -400)
        notify "**Claw Output:**
$OUTPUT"
        echo "$OUTPUT"
        ;;

    pipeline)
        # Sequential chain of $architect / $executor / $reviewer from a single Discord line.
        # Accepts commands like:
        #   $architect analyze X, then $executor fix Y, then $reviewer verify Z
        #   $architect ... $executor ... $reviewer ...   (no "then")
        # Splits on each $role token and dispatches segments sequentially to the
        # architect/executor/reviewer branches above.

        notify "🔗 Pipeline mode: parsing chain..."

        # Strip Discord @mentions (e.g. "@Clawbot", "<@1234567890>") before
        # segmentation so "$@Clawbot" style tokens don't false-match as a role.
        CLEANED=$(echo "$TASK" | sed -E 's/<@!?[0-9]+>//g; s/@[A-Za-z0-9_-]+//g')

        # Normalize: insert | delimiter before each $role token. Handles optional
        # leading "then", leading comma/whitespace, and optional whitespace
        # between the $ and the role name (e.g. "$ reviewer"). The | is safe
        # because it can't appear inside a Discord command for shell reasons.
        NORMALIZED=$(echo "$CLEANED" | sed -E 's/[[:space:],]*then[[:space:]]+\$[[:space:]]*(architect|executor|reviewer)\b/|$\1/g; s/[[:space:]]+\$[[:space:]]*(architect|executor|reviewer)\b/|$\1/g')
        # Strip leading | if the task starts with a $role
        NORMALIZED="${NORMALIZED#|}"

        STEP_COUNT=0
        FAILED_COUNT=0
        IFS='|' read -ra SEGMENTS <<< "$NORMALIZED"
        for seg in "${SEGMENTS[@]}"; do
            # Trim whitespace and trailing commas
            seg=$(echo "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/,$//')
            [ -z "$seg" ] && continue

            # First token is $role, rest is subtask
            ROLE=$(echo "$seg" | awk '{print $1}' | tr -d '$')
            SUBTASK=$(echo "$seg" | cut -d' ' -f2-)

            case "$ROLE" in
                architect|executor|reviewer)
                    STEP_COUNT=$((STEP_COUNT + 1))
                    notify "→ Step $STEP_COUNT: dispatching \$$ROLE"
                    if ! "$0" "$ROLE" "$SUBTASK" "$CHANNEL"; then
                        FAILED_COUNT=$((FAILED_COUNT + 1))
                        notify "⚠️ Step $STEP_COUNT (\$$ROLE) exited non-zero — continuing"
                    fi
                    ;;
                *)
                    notify "⚠️ Pipeline: unknown role '\$$ROLE' — skipping segment"
                    ;;
            esac
        done

        if [ "$STEP_COUNT" -eq 0 ]; then
            notify "❌ Pipeline: no recognizable \$role segments in task. Nothing dispatched."
            exit 1
        fi
        notify "✅ Pipeline complete: $STEP_COUNT step(s), $FAILED_COUNT failure(s)"
        echo "pipeline_steps=$STEP_COUNT pipeline_failures=$FAILED_COUNT"
        ;;

    pipeline-omx)
        # All-OmX pipeline: forces all three roles through OmX regardless
        # of individual ARCHITECT_MODE/EXECUTOR_MODE/REVIEWER_MODE vars.
        export ARCHITECT_MODE=omx EXECUTOR_MODE=omx REVIEWER_MODE=omx
        exec "$0" pipeline "$TASK" "$CHANNEL"
        ;;

    ultrawork)
        SESSION_NAME="ulw-$(date +%s)"
        notify "Spawning ultrawork session: $SESSION_NAME"

        tmux new-session -d -s "$SESSION_NAME" -c "$WORKDIR" \
            "opencode --message 'ulw $TASK' 2>&1; clawhip send --channel $CHANNEL --message 'Ultrawork session $SESSION_NAME completed.'; sleep 5"

        notify "Ultrawork session $SESSION_NAME started in tmux."
        echo "tmux_session=$SESSION_NAME"
        ;;

    *)
        echo "Usage: discord-dispatch.sh <team|architect|executor|reviewer|arch-omx|exec-omx|review-omx|pipeline|pipeline-omx|claw|ultrawork> <task> [channel_id]"
        exit 1
        ;;
esac
