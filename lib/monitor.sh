#!/bin/bash

_monitor_get_df () {
    LXC_EXEC "df / --sync | grep -v Filesystem" >> $TEST_CONTEXT/monitor/$current_test_id/$1-disk
}

_monitor_stats_new_step () {
    mkdir -p $TEST_CONTEXT/monitor/$current_test_id/

    echo "$1" > $TEST_CONTEXT/monitor/$current_test_id/last_step 
    _monitor_get_df $1
}

_monitor_stats_save_last_step () {
    last_step="$(< $TEST_CONTEXT/monitor/$current_test_id/last_step )"

    _monitor_get_df $last_step
    LXC_PULL /tmp/monitordatafile $TEST_CONTEXT/monitor/$current_test_id/$last_step-sysstat
}

_monitor_stats_clean () {
    LXC_EXEC "rm -f /tmp/monitordatafile"
    rm -f $TEST_CONTEXT/monitor/$current_test_id/last_step
}

# FIXME: This could come in the ynh-appci LXC image ?
MONITOR_STATS_SETUP () {
    LXC_EXEC "sh -c 'apt-get install sysstat -y > /dev/null'"
}

MONITOR_STATS_START () {
    nohup lxc exec $LXC_FULLNAME -n -T -- /usr/lib/sysstat/sadc 2 /tmp/monitordatafile > /dev/null 2>&1 &

    _monitor_stats_new_step $1
}

MONITOR_STATS_STEP () {
    MONITOR_STATS_STOP

    MONITOR_STATS_START $1
}

MONITOR_STATS_STOP () {
    LXC_EXEC "pkill sadc"

    _monitor_stats_save_last_step

    _monitor_stats_clean
}

MONITOR_STATS_PROCCESSING () {
    [[ -d "$TEST_CONTEXT/monitor/$current_test_id/" ]] || return 1

    for sysstat in $TEST_CONTEXT/monitor/$current_test_id/*-sysstat ; do
        ram_sorted="$(sar -f $sysstat -r | awk '{print $5}' | sed -e 's/(\d+)/$1/' | sort -nr )"
        max_ram_usage="$(echo $ram_sorted | tr ' ' '\n' | head -n1)"
        min_ram_usage="$(echo $ram_sorted | tr ' ' '\n' | tail -n4 | head -n1)"
        echo "{\"min\":\"$min_ram_usage\", \"max\":\"$max_ram_usage\"}" > $sysstat.json
    done

    for disk in $TEST_CONTEXT/monitor/$current_test_id/*-disk ; do
        before="$(cat $disk | head -n1 | awk '{print $3}' | sed -e 's/(\d+)/$1/')"
        after="$(cat $disk | tail -n1 | awk '{print $3}' | sed -e 's/(\d+)/$1/')"
        echo "{\"before\":\"$before\", \"after\":\"$after\"}" > $disk.json
    done
}