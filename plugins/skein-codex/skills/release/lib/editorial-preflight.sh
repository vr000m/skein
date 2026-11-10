#!/usr/bin/env bash

# Deterministic release-note size metadata. The script deliberately uses only
# Bash builtins so the caller's pinned Bash is the complete executable graph.

LC_ALL=C
LANG=C
export LC_ALL LANG

BODY_LIMIT=3000
BULLET_LIMIT=700
MAX_INPUT_BYTES=65536

fail() {
	exit 1
}

read_to_eof() {
	READ_VALUE=
	IFS= read -r -d '' READ_VALUE
	read_rc=$?
	# With an empty delimiter, read returns success only when it encountered a
	# NUL. Bash variables cannot preserve that byte, so reject the input.
	[[ "$read_rc" -ne 0 ]] || fail
}

byte_value_at() {
	local ch signed
	ch=${BODY_BYTES:$1:1}
	printf -v signed '%d' "'$ch"
	if [[ "$signed" -lt 0 ]]; then
		signed=$((signed + 256))
	fi
	BYTE_VALUE=$signed
}

finalize_record() {
	if [[ "$record_active" -eq 1 && "$record_chars" -gt "$BULLET_LIMIT" ]]; then
		offender_ordinals[offender_count]=$bullet_ordinal
		offender_lengths[offender_count]=$record_chars
		offender_count=$((offender_count + 1))
	fi
}

emit_check() {
	local validated chunk continuation_bytes segment_chars work segment pending
	local offset chunk_length boundary probes has_newline line_start is_last
	read_to_eof
	BODY_BYTES=$READ_VALUE
	byte_count=${#BODY_BYTES}
	[[ "$byte_count" -le "$MAX_INPUT_BYTES" ]] || fail

	total_chars=0
	bullet_ordinal=0
	record_active=0
	record_chars=0
	offender_count=0
	offender_ordinals=()
	offender_lengths=()
	line_start=1
	pending=
	offset=0
	while [[ "$offset" -lt "$byte_count" ]]; do
		chunk_length=256
		if [[ $((offset + chunk_length)) -ge "$byte_count" ]]; then
			chunk_length=$((byte_count - offset))
			is_last=1
		else
			is_last=0
			boundary=$((offset + chunk_length))
			probes=0
			byte_value_at "$boundary"
			while [[ "$BYTE_VALUE" -ge 128 && "$BYTE_VALUE" -le 191 && "$probes" -lt 3 ]]; do
				chunk_length=$((chunk_length - 1))
				boundary=$((boundary - 1))
				probes=$((probes + 1))
				byte_value_at "$boundary"
			done
		fi
		chunk=${BODY_BYTES:$offset:$chunk_length}
		offset=$((offset + chunk_length))

		# Replace valid scalars with ASCII rather than deleting them, so invalid
		# bytes cannot become adjacent and form a new valid sequence.
		if [[ "$chunk" == *[$'\x80'-$'\xff']* ]]; then
			validated=$chunk
			validated=${validated//$'\xe0'[$'\xa0'-$'\xbf'][$'\x80'-$'\xbf']/x}
			validated=${validated//$'\xed'[$'\x80'-$'\x9f'][$'\x80'-$'\xbf']/x}
			validated=${validated//[$'\xe1'-$'\xec'][$'\x80'-$'\xbf'][$'\x80'-$'\xbf']/x}
			validated=${validated//[$'\xee'-$'\xef'][$'\x80'-$'\xbf'][$'\x80'-$'\xbf']/x}
			validated=${validated//$'\xf0'[$'\x90'-$'\xbf'][$'\x80'-$'\xbf'][$'\x80'-$'\xbf']/x}
			validated=${validated//$'\xf4'[$'\x80'-$'\x8f'][$'\x80'-$'\xbf'][$'\x80'-$'\xbf']/x}
			validated=${validated//[$'\xf1'-$'\xf3'][$'\x80'-$'\xbf'][$'\x80'-$'\xbf'][$'\x80'-$'\xbf']/x}
			validated=${validated//[$'\xc2'-$'\xdf'][$'\x80'-$'\xbf']/x}
			[[ "$validated" != *[$'\x80'-$'\xff']* ]] || fail
		fi

		work=$pending$chunk
		pending=
		while [[ -n "$work" ]]; do
			if [[ "$work" == *$'\n'* ]]; then
				segment=${work%%$'\n'*}$'\n'
				work=${work#*$'\n'}
				has_newline=1
			else
				segment=$work
				work=
				has_newline=0
			fi

			if [[ "$line_start" -eq 1 && "$has_newline" -eq 0 && "$is_last" -eq 0 && "${#segment}" -lt 4 ]]; then
				pending=$segment
				continue
			fi
			if [[ "$line_start" -eq 1 ]]; then
				if [[ "$segment" == '- '* || "$segment" == '* '* ]]; then
					finalize_record
					bullet_ordinal=$((bullet_ordinal + 1))
					record_active=1
					record_chars=0
				elif [[ "$segment" == '## '* || "$segment" == '### '* ]]; then
					finalize_record
					record_active=0
					record_chars=0
				fi
				line_start=0
			fi

			if [[ "$segment" != *[$'\x80'-$'\xff']* ]]; then
				segment_chars=${#segment}
			else
				continuation_bytes=${segment//[!$'\x80'-$'\xbf']/}
				segment_chars=$((${#segment} - ${#continuation_bytes}))
			fi
			total_chars=$((total_chars + segment_chars))
			if [[ "$record_active" -eq 1 ]]; then
				record_chars=$((record_chars + segment_chars))
			fi
			if [[ "$has_newline" -eq 1 ]]; then
				line_start=1
			fi
		done
	done

	finalize_record
	warn=0
	if [[ "$total_chars" -gt "$BODY_LIMIT" || "$offender_count" -gt 0 ]]; then
		warn=1
	fi

	printf '1\t%d\t%d\t%d\t%d\t%d\n' \
		"$total_chars" "$BODY_LIMIT" "$BULLET_LIMIT" "$warn" "$offender_count"
	i=0
	while [[ "$i" -lt "$offender_count" ]]; do
		printf '%d\t%d\n' "${offender_ordinals[$i]}" "${offender_lengths[$i]}"
		i=$((i + 1))
	done
}

canonical_uint() {
	[[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
	[[ ${#1} -le 5 ]] || return 1
	[[ "$1" -le "$MAX_INPUT_BYTES" ]] || return 1
}

count_tabs() {
	local value index char
	value=$1
	TAB_COUNT=0
	index=0
	while [[ "$index" -lt "${#value}" ]]; do
		char=${value:$index:1}
		if [[ "$char" == $'\t' ]]; then
			TAB_COUNT=$((TAB_COUNT + 1))
		fi
		index=$((index + 1))
	done
}

validate_result() {
	read_to_eof
	result=$READ_VALUE
	[[ -n "$result" && "$result" == *$'\n' ]] || fail
	payload=${result%$'\n'}
	[[ -n "$payload" ]] || fail
	[[ "$payload" != *$'\n' ]] || fail

	if [[ "$payload" == *$'\n'* ]]; then
		header=${payload%%$'\n'*}
		rest=${payload#*$'\n'}
	else
		header=$payload
		rest=
	fi
	count_tabs "$header"
	[[ "$TAB_COUNT" -eq 5 ]] || fail
	IFS=$'\t' read -r version body_chars body_limit bullet_limit warn expected_count <<<"$header"
	canonical_uint "$version" || fail
	canonical_uint "$body_chars" || fail
	canonical_uint "$body_limit" || fail
	canonical_uint "$bullet_limit" || fail
	canonical_uint "$warn" || fail
	canonical_uint "$expected_count" || fail
	[[ "$version" -eq 1 ]] || fail
	[[ "$body_limit" -eq "$BODY_LIMIT" ]] || fail
	[[ "$bullet_limit" -eq "$BULLET_LIMIT" ]] || fail
	[[ "$warn" -eq 0 || "$warn" -eq 1 ]] || fail

	seen=0
	previous_ordinal=0
	while [[ -n "$rest" ]]; do
		if [[ "$rest" == *$'\n'* ]]; then
			line=${rest%%$'\n'*}
			rest=${rest#*$'\n'}
		else
			line=$rest
			rest=
		fi
		[[ -n "$line" ]] || fail
		count_tabs "$line"
		[[ "$TAB_COUNT" -eq 1 ]] || fail
		IFS=$'\t' read -r ordinal chars <<<"$line"
		canonical_uint "$ordinal" || fail
		canonical_uint "$chars" || fail
		[[ "$ordinal" -ge 1 && "$ordinal" -gt "$previous_ordinal" ]] || fail
		[[ "$chars" -gt "$BULLET_LIMIT" ]] || fail
		previous_ordinal=$ordinal
		seen=$((seen + 1))
	done

	[[ "$seen" -eq "$expected_count" ]] || fail
	expected_warn=0
	if [[ "$body_chars" -gt "$BODY_LIMIT" || "$expected_count" -gt 0 ]]; then
		expected_warn=1
	fi
	[[ "$warn" -eq "$expected_warn" ]] || fail
	printf '%s' "$result"
}

case $#:$1 in
0:)
	emit_check
	;;
1:--validate)
	validate_result
	;;
*)
	fail
	;;
esac
