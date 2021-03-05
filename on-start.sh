#!/usr/bin/env bash

#set -eoux pipefail

# Environment variables passed from Pod env are as follows:
#
#   GROUP_NAME          = a uuid treated as the name of the replication group
#   DB_NAME             = name of the database CR
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

# In a replication topology, we must specify a unique server ID for each replication server, in the range from 1 to 232 − 1.
# “Unique” means that each ID must be different from every other ID in use by any other source or replica in the replication topology
# https://dev.mysql.com/doc/refman/8.0/en/replication-options.html#sysvar_server_id
# the server ID is calculated using the below formula:
# server_id=statefulset_ordinal * 100 + pod_ordinal + 1
if [[ "${BASE_NAME}" == "${DB_NAME}" ]]; then
    declare -i ss_ordinal=0
else
    declare -i ss_ordinal=$(echo -n ${BASE_NAME} | sed -e "s/${DB_NAME}-//g")
fi
declare -i pod_ordinal=$(hostname | sed -e "s/${BASE_NAME}-//g")
declare -i svr_id=$ss_ordinal*100+$pod_ordinal+1

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

# default tls configuration for the group
# group_replication_recovery_use_ssl will be overwritten from DB arguments
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
server_id = ${svr_id}
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
    until "$@"; do
        exit="$?"
        if [ $count -lt $retries ]; then
            log "INFO" "Attempt $count/$retries. Command exited with exit_code: $exit. Retrying after $wait seconds..."
            sleep $wait
        else
            log "INFO" "Command failed in all $retries attempts with exit_code: $exit. Stopping trying any further...."
            return $exit
        fi
        count=$(($count + 1))
    done
    return 0
}

# wait for mysql daemon be running (alive)
function wait_for_mysqld_running() {
    local mysql="$mysql_header --host=127.0.0.1"

    for i in {900..0}; do
        out=$(mysql -N -e "select 1;" 2>/dev/null)
        log "INFO" "Attempt $i: Pinging '$cur_host' has returned: '$out'...................................."
        if [[ "$out" == "1" ]]; then
            break
        fi

        echo -n .
        sleep 1
    done

    if [[ "$i" == "0" ]]; then
        echo ""
        log "ERROR" "Server ${cur_host} failed to start in 900 seconds............."
        exit 1
    fi
    log "INFO" "mysql daemon is ready to use......."
}

function create_replication_user() {
    # now we need to configure a replication user for each server.
    # the procedures for this have been taken by following
    # 01. official doc (section from 17.2.1.3 to 17.2.1.5): https://dev.mysql.com/doc/refman/5.7/en/group-replication-user-credentials.html
    # 02. https://dev.mysql.com/doc/refman/8.0/en/group-replication-secure-user.html
    # 03. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
    log "INFO" "Checking whether replication user exist or not......"
    local mysql="$mysql_header --host=127.0.0.1"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}'
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, crete new one.
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user........"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=0;"
        retry 120 ${mysql} -N -e "CREATE USER 'repl'@'%' IDENTIFIED BY 'password' REQUIRE SSL;"
        retry 120 ${mysql} -N -e "GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';"
        #  You must therefore give the `BACKUP_ADMIN` and `CLONE_ADMIN` privilege to this replication user on all group members that support cloning process
        # https://dev.mysql.com/doc/refman/8.0/en/group-replication-cloning.html
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
        retry 120 ${mysql} -N -e "GRANT BACKUP_ADMIN ON *.* TO 'repl'@'%';"
        retry 120 ${mysql} -N -e "GRANT CLONE_ADMIN ON *.* TO 'repl'@'%';"
        retry 120 ${mysql} -N -e "FLUSH PRIVILEGES;"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=1;"

        retry 120 ${mysql} -N -e "CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='password' FOR CHANNEL 'group_replication_recovery';"
    else
        log "INFO" "Replication user exists. Skipping creating new one......."
    fi
}

function install_group_replication_plugin() {
    log "INFO" "Checking whether replication plugin is installed or not....."
    local mysql="$mysql_header --host=127.0.0.1"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep group_replication
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep group_replication)
    if [[ -z "$out" ]]; then
        log "INFO" "Group replication plugin is not installed. Installing the plugin...."
        # replication plugin will be installed when the member getting bootstrapped or joined into the group first time.
        # that's why assign `joining_for_first_time` variable to 1 for making further reset process.
        joining_for_first_time=1
        retry 120 ${mysql} -e "INSTALL PLUGIN group_replication SONAME 'group_replication.so';"
        log "INFO" "Group replication plugin successfully installed"
    else
        log "INFO" "Already group replication plugin is installed"
    fi
}

function install_clone_plugin() {
    log "INFO" "Checking whether clone plugin is installed or not...."
    local mysql="$mysql_header --host=127.0.0.1"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep clone
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep clone)
    if [[ -z "$out" ]]; then
        log "INFO" "Clone plugin is not installed. Installing the plugin..."
        retry 120 ${mysql} -e "INSTALL PLUGIN clone SONAME 'mysql_clone.so';"
        log "INFO" "Clone plugin successfully installed"
    else
        log "INFO" "Already clone plugin is installed"
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
        log "INFO" "Number of online members: $cluster_size"
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
            log "INFO" "Attempt $i: Checking member list has been updated inside host: $host. Expected online member: $cluster_size. Found: $alive_cluster_size"
            if [[ "$alive_cluster_size" -eq "$cluster_size" ]]; then
                break
            fi
            sleep 1
        done
    done
}

function wait_for_primary() {
    log "INFO" "Waiting for group primary......"
    for host in $@; do
        if [[ "$cur_host" == "$host" ]]; then
            continue
        fi
        local mysql="$mysql_header --host=${host}"

        members_id=$(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';")
        cluster_size=${#members_id[@]}

        local is_primary_found=0
        for member_id in ${members_id[*]}; do
            for i in {60..0}; do
                primary_member_id=$(${mysql} -N -e "SHOW STATUS WHERE Variable_name = 'group_replication_primary_member';" | awk '{print $2}')
                log "INFO" "Attempt $i: Trying to find primary member........................"
                if [[ -n "$primary_member_id" ]]; then
                    is_primary_found=1
                    primary_host=$(${mysql} -N -e "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID = '${primary_member_id}';" | awk '{print $1}')
                    # calculate data size of the primary node.
                    # https://forums.mysql.com/read.php?108,201578,201578
                    primary_db_size=$(${mysql_header} --host=$primary_host -N -e 'select round(sum( data_length + index_length) / 1024 /  1024) "size in mb" from information_schema.tables;')
                    log "INFO" "Primary found. Primary host: $primary_host, database size: $primary_db_size"
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

function set_valid_donors() {
    log "INFO" "Checking whether valid donor is found or not. If found, set this to 'clone_valid_donor_list'"
    local mysql="$mysql_header --host=127.0.0.1"
    # clone process run when the donor and recipient must have the same MySQL server version and
    # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html#:~:text=The%20clone%20plugin%20is%20supported,17%20and%20higher.&text=The%20donor%20and%20recipient%20MySQL%20server%20instances%20must%20run,same%20operating%20system%20and%20platform.
    cur_host_version=$(${mysql} -N -e "SHOW VARIABLES LIKE 'version';" | awk '{print $2}')

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql_header} --host=$primary_host -N -e "SELECT * FROM performance_schema.replication_group_members;"

    donor_list=$(${mysql_header} --host=$primary_host -N -e "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';")
    valid_donor_found=0
    for donor in ${donor_list[*]}; do
        donor_version=$(${mysql_header} --host=$primary_host -N -e "SELECT MEMBER_VERSION FROM performance_schema.replication_group_members WHERE MEMBER_HOST = '${donor}';" | awk '{print $1}')
        if [[ "$cur_host_version" == "$donor_version" ]]; then
            donors=("${donors[@]}" "$donor")
            valid_donor_found=1
        fi
    done

    if [[ $valid_donor_found == 1 ]]; then
        valid_donors=$(echo -n ${donors[*]} | sed -e "s/ /:3306,/g" && echo -n ":3306")
        log "INFO" "Valid donors found. The list of valid donor are: ${valid_donors}"
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-options-variables.html#sysvar_clone_valid_donor_list
        retry 120 ${mysql} -N -e "SET GLOBAL clone_valid_donor_list='${valid_donors}';"
    fi
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
    log "INFO" "bootstrapping cluster with host $cur_host..."
    if [[ "$joining_for_first_time" == "1" ]]; then
        retry 120 ${mysql} -N -e "RESET MASTER;"
    fi
    retry 120 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=ON;"
    retry 120 ${mysql} -N -e "START GROUP_REPLICATION USER='repl', PASSWORD='password';"
    retry 120 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=OFF;"
}

function join_into_cluster() {
    # member try to join into the existing group
    log "INFO" "The replica, ${cur_host} is joining into the existing group..."
    local mysql="$mysql_header --host=127.0.0.1"

    # for 1st time joining, there need to run `RESET MASTER` to set the binlog and gtid's initial position.
    # then run clone process to copy data directly from valid donor. That's why pod will be restart for 1st time joining into the group replication.
    # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
    mysqld_alive=1
    if [[ "$joining_for_first_time" == "1" ]]; then
        log "INFO" "Resetting binlog & gtid to initial state as $cur_host is joining for first time.."
        retry 120 ${mysql} -N -e "RESET MASTER;"
        # clone process will run when the joiner get valid donor and the primary member's data will be be gather or equal than 128MB
        if [[ $valid_donor_found == 1 ]] && [ $primary_db_size -ge 128 ]; then
            for donor in ${donors[*]}; do
                log "INFO" "Cloning data from $donor to $cur_host....."
                error_message=$(${mysql} -N -e "CLONE INSTANCE FROM 'repl'@'$donor':3306 IDENTIFIED BY 'password' REQUIRE SSL;" 2>&1)
                # we may get an error when the cloning process has finished like:
                # ".ERROR 3707 (HY000) at line 1: Restart server failed (mysqld is not managed by supervisor process)"
                # This error does not indicate a cloning failure.
                # It means that the recipient MySQL server instance must be started again manually after the data is cloned
                # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html#:~:text=ERROR%203707%20(HY000)%3A%20Restart,not%20managed%20by%20supervisor%20process).&text=It%20means%20that%20the%20recipient,after%20the%20data%20is%20cloned.
                log "INFO" "Clone error message: $error_message"
                if [[ "$error_message" != *"mysqld is not managed by supervisor process"* ]]; then
                    # retry cloning process for next valid donor
                    continue
                fi

                # wait for background process `mysqld` have been killed
                for i in {120..0}; do
                    kill -0 $pid
                    exit="$?"
                    log "INFO" "Attempt $i: Checking mysqld(process id=$pid) is alive or not, exit code: $exit"
                    if [[ "$exit" != "0" ]]; then
                        mysqld_alive=0
                        break
                    fi
                    echo -n .
                    sleep 1
                done

                if [[ "$mysqld_alive" == "0" ]]; then
                    break
                fi

            done
        fi
    fi
    # If the host is still alive, it will join the cluster directly.
    if [[ $mysqld_alive == 1 ]]; then
        retry 120 ${mysql} -N -e "START GROUP_REPLICATION USER='repl', PASSWORD='password';"
        log "INFO" "Host (${cur_host}) has joined to the group......."
    fi
}

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}
export member_hosts=$(echo -n ${hosts} | sed -e "s/,/ /g")
export joining_for_first_time=0
log "INFO" "Host lists: $member_hosts"

# wait for mysqld to be ready
wait_for_mysqld_running

# ensure replication user
create_replication_user

# ensure replication plugin
install_group_replication_plugin

# ensure clone plugin
install_clone_plugin

# check for existing cluster
check_existing_cluster "${member_hosts[*]}"

if [[ "$cluster_exists" == "1" ]]; then
    check_member_list_updated "${member_hosts[*]}"
    wait_for_primary "${member_hosts[*]}"
    set_valid_donors
    join_into_cluster
else
    bootstrap_cluster
fi

# wait for mysqld process running in background
log "INFO" "Waiting for mysqld process running in foreground..."
wait $pid
