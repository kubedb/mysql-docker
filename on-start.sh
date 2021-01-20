#!/usr/bin/env bash

#set -eoux pipefail

# Environment variables passed from Pod env are as follows:
#
#   GROUP_NAME          = a uuid treated as the name of the replication group
#   BASE_NAME           = name of the StatefulSet (same as the name of CRD)
#   BASE_SERVER_ID      = server-id of the primary member
#   GOV_SVC             = the name of the governing service
#   POD_NAMESPACE       = the Pods' namespace
#   MYSQL_ROOT_USERNAME = root user name
#   MYSQL_ROOT_PASSWORD = root password

script_name=${0##*/}
NAMESPACE="$POD_NAMESPACE"
USER="$MYSQL_ROOT_USERNAME"
PASSWORD="$MYSQL_ROOT_PASSWORD"

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

# get_host_name() expects only one argument and that is the index of the Pod of StatefulSet.
# And it forms the FQDN (Fully Qualified Domain Name) of the $1'th Pod of StatefulSet.
function get_host_name() {
    #  echo -n "$BASE_NAME-$1.$GOV_SVC.$NAMESPACE.svc.cluster.local"
    echo -n "$BASE_NAME-$1.$GOV_SVC.$NAMESPACE"
}

# get the host names from stdin sent by peer-finder program
cur_hostname=$(hostname)
export cur_host=
log "INFO" "Reading standard input..."
while read -ra line; do
    if [[ "${line}" == *"${cur_hostname}"* ]]; then
        #    cur_host="$line"
        cur_host=$(echo -n ${line} | sed -e "s/.svc.cluster.local//g")
        log "INFO" "I am $cur_host"
    fi
    #  peers=("${peers[@]}" "$line")
    tmp=$(echo -n ${line} | sed -e "s/.svc.cluster.local//g")
    peers=("${peers[@]}" "$tmp")

done
log "INFO" "Trying to start group with peers'${peers[*]}'"

# store the value for the variables those will be written in /etc/mysql/my.cnf file

# comma separated host names
export hosts=$(echo -n ${peers[*]} | sed -e "s/ /,/g")

# comma separated seed addresses of the hosts (host1:port1,host2:port2,...)
export seeds=$(echo -n ${hosts} | sed -e "s/,/:33061,/g" && echo -n ":33061")

# server-id calculated as $BASE_SERVER_ID + pod index
declare -i srv_id=$(hostname | sed -e "s/${BASE_NAME}-//g")
((srv_id += $BASE_SERVER_ID))

export cur_addr="${cur_host}:33061"

# Get ip_whitelist
# https://dev.mysql.com/doc/refman/5.7/en/group-replication-options.html#sysvar_group_replication_ip_whitelist
# https://dev.mysql.com/doc/refman/5.7/en/group-replication-ip-address-whitelisting.html
#
# Command $(hostname -I) returns a space separated IP list. We need only the first one.
myips=$(hostname -I)
first=${myips%% *}
# Now use this IP with CIDR notation
export whitelist="${first}/8"
# the mysqld configurations have take by following
# 01. official doc: https://dev.mysql.com/doc/refman/5.7/en/group-replication-configuring-instances.html
# 02. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
log "INFO" "Storing default mysqld config into /etc/mysql/my.cnf"
mkdir -p /etc/mysql/group-replication.conf.d/
echo "!includedir /etc/mysql/group-replication.conf.d/" >>/etc/mysql/my.cnf

cat >>/etc/mysql/group-replication.conf.d/group.cnf <<EOL
[mysqld]
default-authentication-plugin=mysql_native_password
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"

# General replication settings
gtid_mode = ON
enforce_gtid_consistency = ON
master_info_repository = TABLE
relay_log_info_repository = TABLE
binlog_checksum = NONE
log_slave_updates = ON
log_bin = binlog
binlog_format = ROW
transaction_write_set_extraction = XXHASH64
loose-group_replication_bootstrap_group = OFF
loose-group_replication_start_on_boot = OFF
loose-group_replication_ssl_mode = REQUIRED
loose-group_replication_recovery_use_ssl = 1

# Shared replication group configuration
loose-group_replication_group_name = "${GROUP_NAME}"
loose-group_replication_ip_whitelist = "${whitelist}"
loose-group_replication_group_seeds = "${seeds}"

# Single or Multi-primary mode? Uncomment these two lines
# for multi-primary mode, where any host can accept writes
#loose-group_replication_single_primary_mode = OFF
#loose-group_replication_enforce_update_everywhere_checks = ON

# Host specific replication configuration
server_id = ${srv_id}
#bind-address = "${cur_host}"
bind-address = "0.0.0.0"
report_host = "${cur_host}"
loose-group_replication_local_address = "${cur_addr}"
EOL

# run the mysqld process in background with user provided arguments if any
log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld $@'..."
docker-entrypoint.sh mysqld $@ &

pid=$!
log "INFO" "The process id of mysqld is '$pid'"

# retry a command up to a specific number of times until it exits successfully,
function retry {
    local retries="$1"
    shift

    local count=0
    local wait=1
    until "$@" ; do
        exit="$?"
        count=$(($count + 1))
        if [ $count -lt $retries ]; then
            echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
            sleep $wait
        else
            echo "Retry $count/$retries exited $exit, no more retries left."
            return $exit
        fi
    done
    return 0
}

function wait_for_mysqld_running() {
    # wait for mysql daemon be running (alive)
    local mysql="$mysql_header --host=127.0.0.1"

    for i in {900..0}; do
        out=$(mysql -N -e "select 1;" 2>/dev/null)
        log "INFO" "Trying to ping for host: '$cur_host', Got=====>'$out', Step=====>'$i'"
        if [[ "$out" == "1" ]]; then
            break
        fi

        echo -n .
        sleep 1
    done

    if [[ "$i" == "0" ]]; then
        echo ""
        log "ERROR" "Server ${cur_host} start failed..."
        exit 1
    fi
    log "INFO" "mysql daemon is ready to use for host: (${cur_host}) ..."
}

function create_replication_user() {
    # now we need to configure a replication user for each server.
    # the procedures for this have been taken by following
    # 01. official doc (section from 17.2.1.3 to 17.2.1.5): https://dev.mysql.com/doc/refman/5.7/en/group-replication-user-credentials.html
    # 02. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
    log "INFO" "Checking whether replication user exist or not for host: ${cur_host}..."
    local mysql="$mysql_header --host=127.0.0.1"

    # 1st try to find the the group `repl` user without error, then extract the out whether replication user exist or not
    retry 120 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}'
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, crete new one.
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found and creating one..."
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=0;"
        retry 120 ${mysql} -N -e "CREATE USER 'repl'@'%' IDENTIFIED BY 'password' REQUIRE SSL;"
        retry 120 ${mysql} -N -e "GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';"
        retry 120 ${mysql} -N -e "FLUSH PRIVILEGES;"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=1;"

        retry 120 ${mysql} -N -e "CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='password' FOR CHANNEL 'group_replication_recovery';"
    else
        log "INFO" "Replication user info exists"
    fi
}

function install_group_replication_plugin() {
    # ensure the group replication plugin be installed
    log "INFO" "Checking whether group replication plugin is installed or not..."
    local mysql="$mysql_header --host=127.0.0.1"

     # 1st try to find the the group replication plugin installed without error, then extract the out whether plugin exists or not
    retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep group_replication
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep group_replication)
    if [[ -z "$out" ]]; then
        log "INFO" "Group replication plugin is not installed. Installing the plugin..."
        # replication plugin will be install when the member get bootstrap face or join the group first
        # that's why assign `joining_for_first_time` variable to 1 for taking further reset process
        joining_for_first_time=1
        retry 120 ${mysql} -e "INSTALL PLUGIN group_replication SONAME 'group_replication.so';"
        log "INFO" "Group replication plugin successfully installed"
    else
        log "INFO" "Already group replication plugin is installed"
    fi
}

function check_existing_cluster() {
    log "INFO" "Checking whether there exists any replication group or not..."
    cluster_exists=0
    for host in $@; do
        if [[ "$cur_host" == "$host" ]]; then
            continue
        fi
        local mysql="$mysql_header --host=${host}"

        members_id=($(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';"))
        cluster_size=${#members_id[@]}
        log "INFO" "The size of existing cluster is $cluster_size"
        if [[ "$cluster_size" -ge "1" ]]; then
            cluster_exists=1
            break
        fi
    done
}

function check_member_list_updated() {
    for host in $@; do
        local mysql="$mysql_header --host=$host"
        if [[ "$cur_host" == "$host" ]]; then
            continue
        fi
        for i in {60..0}; do
            alive_members_id=($(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';"))
            alive_cluster_size=${#alive_members_id[@]}
            listed_members_id=($(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members;"))
            cluster_size=${#listed_members_id[@]}

            log "INFO" "Checking mysql cluster is updated for host: $host, online===> $alive_cluster_size total listed member===> $cluster_size, step===> $i"
            if [[ "$alive_cluster_size" -eq "$cluster_size" ]]; then
                break
            fi
            sleep 1
        done
    done
}

function wait_for_primary() {
    log "INFO" "Waiting for mysql group primary..."
    for host in $@; do
        if [[ "$cur_host" == "$host" ]]; then
            continue
        fi
        local mysql="$mysql_header --host=${host}"

        members_id=$(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';")
        cluster_size=${#members_id[@]}
        log "INFO" "The size of existing alive cluster is $cluster_size"

        local is_primary_found=0
        for member_id in ${members_id[*]}; do
            for i in {60..0}; do
                primary_member_id=$(${mysql} -N -e "SHOW STATUS WHERE Variable_name = 'group_replication_primary_member';" | awk '{print $2}')
                log "INFO" "Trying to match updated primary member id with others replica, got primary=$primary_member_id and replica=$member_id, step=====>$i"
                if [[ "$member_id" == "$primary_member_id" ]]; then
                    is_primary_found=1
                    primary_host=$(${mysql} -N -e "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID = '${primary_member_id}';" | awk '{print $1}')
                    log "INFO" "In existing group replication, found primary: $primary_host"
                    break
                fi

                echo -n .
                sleep 1
            done

            if [[ "$is_primary_found" == "1" ]]; then
                break
            fi

        done

        if [[ "$is_primary_found" == "1" ]]; then
            break
        fi
    done
}

function bootstrap_cluster() {
    # for bootstrap group replication, the following steps have been taken:
    # - initially reset the member to cleanup all data configuration/set the binlog and gtid's initial position.
    #   ref: https://dev.mysql.com/doc/refman/8.0/en/reset-master.html
    # - set global variable group_replication_bootstrap_group to `ON`
    # - start group replication
    # - set global variable group_replication_bootstrap_group to `OFF`
    #   ref:  https://dev.mysql.com/doc/refman/8.0/en/group-replication-bootstrap.html
    local mysql="$mysql_header --host=127.0.0.1"
    log "INFO" "run 'RESET MASTER' for primary at bootstrap time, host $cur_host..."
    retry 120 ${mysql} -N -e "RESET MASTER;"
    retry 120 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=ON;"
    retry 120 ${mysql} -N -e "START GROUP_REPLICATION;"
    retry 120 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=OFF;"
}

function join_into_cluster() {
    # member try to join into the existing group
    log "INFO" "The replica, ${cur_host} is joining into the existing group..."
    local mysql="$mysql_header --host=127.0.0.1"

    # for 1st time joining, there need to run `RESET MASTER` to set the binlog and gtid's initial position.
    if [[ "$joining_for_first_time" == "1" ]]; then
        log "INFO" "Resetting binlog & gtid to initial state as $cur_host is joining for first time.."
        retry 120 ${mysql} -N -e "RESET MASTER;"
    fi

     # run `START GROUP_REPLICATION` until the the member successfully join into the group
    retry 120 ${mysql} -N -e "START GROUP_REPLICATION;"
    log "INFO" "Group replication on (${cur_host}) has been taken place..."
}

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}
export member_hosts=$(echo -n ${hosts} | sed -e "s/,/ /g")
export joining_for_first_time=0
log "INFO" "Existing member in the group are: $member_hosts"

# wait for mysqld is getting ready for listen and serve
wait_for_mysqld_running

# ensure replication user for the group
create_replication_user

# ensure replication plugin is installed
install_group_replication_plugin

# checking group replication existence
check_existing_cluster "${member_hosts[*]}"

# set primary host in replica 0 for 1st time bootstrap
# it will be override in `wait_for_primary` function when it will get the updated primary host
export primary_host=$(get_host_name 0)

if [[ "$cluster_exists" == "1" ]]; then
    wait_for_primary "${member_hosts[*]}"
    check_member_list_updated "${member_hosts[*]}"
    join_into_cluster
else
    bootstrap_cluster
fi

# wait for mysqld process running in background
log "INFO" "Waiting for mysqld process running in foreground..."
wait $pid
