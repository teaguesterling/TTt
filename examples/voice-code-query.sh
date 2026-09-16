#!/usr/bin/env bash
# Ask a codebase a question out loud, and hear the answer.
#
#   voice-code-query.sh [DIR]
#
# The whole thing is pipes. Every stage is a command that reads stdin and
# writes stdout, which is the point of this example more than the demo itself:
#
#   ttt listen        microphone -> text        (device ASR)
#   ttt prompt        text -> a CSS selector    (device chat model + a card)
#   duckeye -Q        selector -> matching code (sitting_duck, local, no model)
#   ttt prompt        code -> a summary         (device chat model)
#   ttt say --play    summary -> speech         (device TTS)
#
# Bind it to a hotkey and you can ask "where do we call db.execute in the
# importer?" without touching the keyboard.
#
# Requirements: ttt (this repo) and duckeye on PATH, a chat model loaded on the
# device (`ttt load fast`), and a microphone.
#
# The selector step needs a prompt that teaches the model your selector
# vocabulary. Point TTT_SELECTOR_CARD at one; a starter is beside this script.
# A model fine-tuned for the job would replace the card entirely — set
# TTT_SELECTOR_MODEL to use it.
set -uo pipefail

DIR="${1:-$PWD}"
CARD="${TTT_SELECTOR_CARD:-$(dirname "$0")/selector-card.md}"
SECS="${TTT_LISTEN_SECONDS:-6}"
TTT="$(dirname "$0")/../bin/ttt"
[ -x "$TTT" ] || TTT="$(command -v ttt)" || { echo "ttt not found" >&2; exit 1; }
command -v duckeye >/dev/null 2>&1 || { echo "duckeye not found" >&2; exit 1; }
[ -f "$CARD" ] || { echo "no selector card at $CARD (set TTT_SELECTOR_CARD)" >&2; exit 1; }

say() { "$TTT" say "$1" --play >/dev/null 2>&1 || true; }

# 1. listen ------------------------------------------------------------------
question="$("$TTT" listen --seconds "$SECS")" || exit 1
[ -n "$question" ] || { echo "heard nothing" >&2; exit 1; }
echo "heard:    $question" >&2

# 2. question -> selector ----------------------------------------------------
# The card ends with {{input}}, so the question lands where the examples are.
selector="$(printf '%s' "$question" | "$TTT" prompt --template "$CARD" \
            ${TTT_SELECTOR_MODEL:+--model "$TTT_SELECTOR_MODEL"} | head -1 | tr -d '`')"
[ -n "$selector" ] || { echo "no selector produced" >&2; exit 1; }
echo "selector: $selector" >&2

# 3. selector -> matching code ----------------------------------------------
# duckeye does the retrieval locally: no model, no network, just the AST.
hits="$(duckeye -Q "$selector" "$DIR" 2>/dev/null)" || true
if [ -z "$hits" ]; then
  echo "no matches for $selector in $DIR" >&2
  say "Nothing matched that selector."
  exit 0
fi
printf '%s\n' "$hits"

# 4. code -> summary ---------------------------------------------------------
summary="$(printf 'Question: %s\n\nMatches:\n%s\n' "$question" "$hits" \
           | head -c 12000 \
           | "$TTT" prompt "Answer the question from these code matches in two sentences. Name files and line numbers.")"
echo
echo "$summary"

# 5. summary -> speech -------------------------------------------------------
printf '%s' "$summary" | "$TTT" say --play
