#!/bin/bash

#=================================================
# RUNNING SNAPSHOT
#=================================================

LXC_CREATE () {
    log_info "Launching new LXC $LXC_FULLNAME ..."
    # Check if we can launch container from yunohost remote image
    if lxc remote list | grep -q "yunohost" && lxc image list yunohost:$LXC_BASE | grep -q -w $LXC_BASE; then
        lxc launch yunohost:$LXC_BASE $LXC_FULLNAME \
            -p yunohost-ci \
            >>/proc/self/fd/3
    # Check if we can launch container from a local image
    elif lxc image list $LXC_REMOTE: $LXC_BASE | grep -q -w $LXC_BASE; then
        lxc launch $LXC_BASE $LXC_FULLNAME \
            -p yunohost-ci \
            >>/proc/self/fd/3
    else
        log_critical "Can't find base image $LXC_BASE, run ./package_check.sh --rebuild"
    fi
    
    pipestatus="${PIPESTATUS[0]}"
    location=$(lxc list $LXC_REMOTE: --format json | jq -e --arg LXC_NAME $LXC_NAME '.[] | select(.name==$LXC_NAME) | .location' | tr -d '"')
    [[ "$location" != "none" ]] && log_info "... on $location"

    [[ "$pipestatus" -eq 0 ]] || exit 1

    _LXC_START_AND_WAIT $LXC_FULLNAME
    set_witness_files
    MONITOR_STATS_SETUP
    lxc snapshot $LXC_FULLNAME snap0
}

LXC_SNAPSHOT_EXISTS() {
    local snapname=$1
    lxc list $LXC_REMOTE: --format json \
        | jq -e --arg LXC_NAME $LXC_NAME --arg snapname $snapname \
        '.[] | select(.name==$LXC_NAME) | .snapshots[] | select(.name==$snapname)' \
            >/dev/null
}

CREATE_LXC_SNAPSHOT () {
    # Create a temporary snapshot

    local snapname=$1

    start_timer

    # Check all the witness files, to verify if them still here
    check_witness_files >&2

    # Remove swap files to avoid killing the CI with huge snapshots.
    CLEAN_SWAPFILES
    
    LXC_STOP $LXC_FULLNAME

    # Check if the snapshot already exist
    if ! LXC_SNAPSHOT_EXISTS "$snapname"
    then
        log_info "(Creating snapshot $snapname ...)"
        lxc snapshot $LXC_FULLNAME $snapname
    fi

    _LXC_START_AND_WAIT $LXC_FULLNAME

    stop_timer 1
}

LOAD_LXC_SNAPSHOT () {
    local snapname=$1
    log_debug "Loading snapshot $snapname ..."

    # Remove swap files before restoring the snapshot.
    CLEAN_SWAPFILES

    LXC_STOP $LXC_FULLNAME

    lxc restore $LXC_FULLNAME $snapname
    lxc start $LXC_FULLNAME
    _LXC_START_AND_WAIT $LXC_FULLNAME
}

#=================================================

LXC_EXEC () {
    # Start the lxc container and execute the given command in it
    local cmd=$1

    _LXC_START_AND_WAIT $LXC_FULLNAME

    start_timer

    # Execute the command given in argument in the container and log its results.
    lxc exec $LXC_FULLNAME --env PACKAGE_CHECK_EXEC=1 -t -- /bin/bash -c "$cmd" | tee -a "$complete_log" $current_test_log

    # Store the return code of the command
    local returncode=${PIPESTATUS[0]}

    log_debug "Return code: $returncode"

    stop_timer 1
    # Return the exit code of the ssh command
    return $returncode
}

LXC_PULL () {
    local path=$1
    local dest=$2

    _LXC_START_AND_WAIT $LXC_FULLNAME

    lxc file pull $LXC_FULLNAME$1 $2
}

LXC_STOP () {
    local container_to_stop=$1
    # (We also use timeout 30 in front of the command because sometime lxc
    # commands can hang forever despite the --timeout >_>...)
    timeout 30 lxc stop --timeout 15 $container_to_stop 2>/dev/null

    # If the command times out, then add the option --force
    if [ $? -eq 124 ]; then
        timeout 30 lxc stop --timeout 15 $container_to_stop --force 2>/dev/null
    fi
}

LXC_RESET () {
    # If the container exists
    if lxc info $LXC_FULLNAME >/dev/null 2>/dev/null; then
        # Remove swap files before deletting the continer
        CLEAN_SWAPFILES
    fi 

    LXC_STOP $LXC_FULLNAME

    lxc delete $LXC_FULLNAME --force 2>/dev/null
}


_LXC_START_AND_WAIT() {

	restart_container()
	{
        LXC_STOP $1
		lxc start "$1"
	}

	# Try to start the container 3 times.
	local max_try=3
	local i=0
	while [ $i -lt $max_try ]
	do
		i=$(( i +1 ))
		local failstart=0

		# Wait for container to start, we are using systemd to check this,
		# for the sake of brevity.
		for j in $(seq 1 10); do
			if lxc exec "$1" -- systemctl isolate multi-user.target >/dev/null 2>/dev/null; then
				break
			fi

			if [ "$j" == "10" ]; then
				log_debug 'Failed to start the container ... restarting ...'
				failstart=1

				restart_container "$1"
			fi

			sleep 1s
		done

		# Wait for container to access the internet
		for j in $(seq 1 10); do
			if lxc exec "$1" -- curl -s http://wikipedia.org > /dev/null 2>/dev/null; then
				break
			fi

			if [ "$j" == "10" ]; then
				log_debug 'Failed to access the internet ... restarting'
				failstart=1

				restart_container "$1"
			fi

			sleep 1s
		done

		# Has started and has access to the internet
		if [ $failstart -eq 0 ]
		then
			break
		fi

		# Fail if the container failed to start
		if [ $i -eq $max_try ] && [ $failstart -eq 1 ]
		then
            log_error "The container miserably failed to start or to connect to the internet"
            lxc info --show-log $1
			return 1
		fi
	done

    LXC_IP=$(lxc exec $1 -- hostname -I | grep -E -o "\<[0-9.]{8,}\>")
}

CLEAN_SWAPFILES() {
    # Restart it if needed
    if [ "$(lxc info $LXC_FULLNAME | grep Status | awk '{print tolower($2)}')" != "running" ]; then
        lxc start $LXC_FULLNAME
        _LXC_START_AND_WAIT $LXC_FULLNAME
    fi
    lxc exec $LXC_FULLNAME -- bash -c 'for swapfile in $(ls /swap_* 2>/dev/null); do swapoff $swapfile; done'
    lxc exec $LXC_FULLNAME -- bash -c 'for swapfile in $(ls /swap_* 2>/dev/null); do rm -f $swapfile; done'
}

RUN_INSIDE_LXC() {
    lxc exec $LXC_FULLNAME -- "$@"
}

