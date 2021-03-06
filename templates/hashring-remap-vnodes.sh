#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

#
# This script will use the pristine copy of the hash ring database previously
# unpacked in the workspace directory, marking all of the vnodes for a
# particular pnode as read-only.
#

NODE='/opt/smartdc/electric-moray/build/node/bin/node'
EM_BIN='/opt/smartdc/electric-moray/node_modules/.bin'
FASH="$EM_BIN/fash"

export PATH='/usr/bin:/usr/sbin:/sbin'

workspace='/var/tmp/reshard.%%WORKSPACE_ID%%'
shard='tcp://%%SHARD%%:2020'
new_shard='tcp://%%NEW_SHARD%%:2020'

if [[ ! -d "$workspace/hash_ring" ]]; then
	printf 'ERROR: no hash ring in workspace directory: %s\n' \
	    "$workspace" >&2
	exit 1
fi

if ! cd "$workspace"; then
	printf 'ERROR: could not chdir into workspace\n' >&2
	exit 1
fi

st_pid=$$
st_total_vnodes=null
st_processed_vnodes=null
st_start_time=$(date -u '+%FT%TZ')
st_finished=false
st_error=false
st_zonename=$(zonename)

function post_status {
	local retrycount=

	for (( retrycount = 0; retrycount < 25; retrycount++ )); do
		if curl --max-time 30 -sSf -X POST \
		    -H 'Content-Type: application/json' -d '@-' \
		    "%%STATUS_URL%%"; then
			return 0
		fi <<-EOF
		{
			"pid": $st_pid,
			"start_time": "$st_start_time",
			"total_vnodes": $st_total_vnodes,
			"processed_vnodes": $st_processed_vnodes,
			"message": "$1",
			"finished": $st_finished,
			"error": $st_error,
			"zonename": "$st_zonename",
			"workspace": "$workspace"
		}
		EOF

		printf 'WARNING: status POST failed (retry %d)\n' \
		    "$retrycount" >&2
		sleep 5
	done

	printf 'FATAL: could not POST status to reshard server\n' >&2
	exit 1
}

function fatal {
	printf 'ERROR: %s\n' "$1" >&2

	st_error=true
	post_status "ERROR: $1"

	exit 1
}

#
# These arguments are common to each invocation of the "fash" command,
# directing it to use the LevelDB backend for the hash ring database in
# our workspace directory.
#
FASHARGS=(
	'-b' 'leveldb'
	'-l' "$workspace/hash_ring"
)

#
# Load the full list of vnodes currently mapped to the target shard (pnode).
#
post_status 'loading vnode list'
if ! vnodes_out=$("$NODE" "$FASH" get-vnodes "${FASHARGS[@]}" "$shard") ||
    [[ -z $vnodes_out ]]; then
	fatal 'could not load vnode list'
fi

#
# The output format of the vnode list is a bit unfortunate; rather than a
# single vnode appearing on each line, or even being JSON-formatted,
# the output comes from the "util.inspect()" routine.  The output is
# therefore _similar_ to JSON, but not close enough to be useful with
# regular JSON tools.  We will hold our collective noses, and pull it apart
# with "awk".
#
post_status 'processing vnode list'
if ! vnodes=( $(awk '{ gsub("[^0-9]", "", $0); printf("%d\n", $0); }' \
    <<< "$vnodes_out") ); then
	fatal 'could not post-process vnode list'
fi

st_total_vnodes=${#vnodes[@]}
st_processed_vnodes=0
post_status 'remapping vnodes'

if (( st_total_vnodes < 2 )); then
	fatal 'less than 2 vnodes found'
fi

while :; do
	if (( st_processed_vnodes >= ${#vnodes[@]} )); then
		break
	fi

	#
	# Batch the linefeed delimited list of entries into 1000 entry
	# comma-separated chunks.  By marking multiple vnodes in a single
	# "fash" invocation, we can greatly improve the performance of the
	# entire operation.
	#
	batch=
	for (( nbatch = 0; nbatch < 1000 && st_processed_vnodes < ${#vnodes[@]};
	    nbatch++ )); do
		vi=$(( st_processed_vnodes++ ))
		if (( vi % 2 != 0 )); then
			#
			# As we are splitting this shard in half, skip every
			# second vnode.
			#
			continue
		fi
		if (( nbatch > 0 )); then
			batch+=','
		fi
		batch+=${vnodes[$vi]}
	done

	if ! "$NODE" "$FASH" remap-vnode "${FASHARGS[@]}" -v "$batch" \
	    -p "$new_shard" >/dev/null; then
		fatal 'could not remap vnodes'
	fi

	post_status 'remapping vnodes'
done

st_finished=true
post_status 'remap complete'
