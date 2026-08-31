#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
delta_dir="${EVENT_DELTA_DIR:-$repo_dir/events/deltas}"
graph_event_types="${GRAPH_EVENT_TYPES_FILE:-$repo_dir/events/graph-event-types.list}"
conditional_entity_graph_event_types="${CONDITIONAL_ENTITY_GRAPH_EVENT_TYPES_FILE:-$repo_dir/events/conditional-entity-graph-event-types.list}"
rejected_graph_event_types="${REJECTED_GRAPH_EVENT_TYPES_FILE:-$repo_dir/events/rejected-graph-event-types.list}"
superseded_delta_file="${EVENT_SUPERSEDED_DELTA_FILE:-$delta_dir/superseded-deltas.list}"
failed=false

[[ -f "$graph_event_types" ]] || {
  printf 'missing graph event type registry: %s\n' "$graph_event_types" >&2
  exit 1
}
[[ -f "$rejected_graph_event_types" ]] || {
  printf 'missing rejected graph event type registry: %s\n' "$rejected_graph_event_types" >&2
  exit 1
}
[[ -f "$conditional_entity_graph_event_types" ]] || {
  printf 'missing conditional entity graph event type registry: %s\n' "$conditional_entity_graph_event_types" >&2
  exit 1
}

is_superseded_delta() {
  local delta_id="$1"

  [[ -f "$superseded_delta_file" ]] || return 1
  awk '
    /^[[:space:]]*(#|$)/ { next }
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    $0 == target { found = 1 }
    END { exit(found ? 0 : 1) }
  ' target="$delta_id" "$superseded_delta_file"
}

while IFS= read -r delta; do
  delta_id="$(basename -- "$delta" .json)"
  if is_superseded_delta "$delta_id"; then
    continue
  fi

  invalid="$(jq -r \
    --rawfile graph_types "$graph_event_types" \
    --rawfile conditional_entity_types "$conditional_entity_graph_event_types" \
    --rawfile rejected_types "$rejected_graph_event_types" '
    ($graph_types | split("\n") |
      map(select(length > 0 and (startswith("#") | not)))) as $graph_types |
    ($rejected_types | split("\n") |
      map(select(length > 0 and (startswith("#") | not)))) as $rejected_types |
    ($conditional_entity_types | split("\n") |
      map(select(length > 0 and (startswith("#") | not)))) as $conditional_entity_types |
    .[] |
    .type as $type |
    if ($rejected_types | index($type)) != null then
      "\(.id // "<missing-id>") type=\($type) unsupportedGraphEvent=true"
    elif (
      ($graph_types | index($type)) != null
      and (
        ($conditional_entity_types | index($type)) == null
        or (.data.entityType // "" | ascii_downcase) == "instance"
      )
    ) then
      (if ($type | endswith("CreatedEvent")) then "CREATE" else "MUTATION" end) as $expected |
      select((.commandkind // "") != $expected or has("nonce")) |
      "\(.id // "<missing-id>") type=\($type) expectedCommandKind=\($expected) actualCommandKind=\(.commandkind // "<missing>") hasNonce=\(has("nonce"))"
    else
      empty
    end
  ' "$delta")"

  if [[ -n "$invalid" ]]; then
    printf '%s:\n%s\n' "$delta" "$invalid" >&2
    failed=true
  fi
done < <(find "$delta_dir" -maxdepth 1 -type f -name '*.json' | sort)

if [[ "$failed" == true ]]; then
  printf 'event delta validation failed\n' >&2
  exit 1
fi

printf 'event delta validation passed\n'
