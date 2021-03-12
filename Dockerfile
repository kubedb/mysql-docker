FROM mysql:5.7.31

COPY on-start.sh /
COPY peer-finder /usr/local/bin/peer-finder

VOLUME /etc/mysql

# For standalone mysql
# default entrypoint of parent mysql:5.7.31
# ENTRYPOINT ["docker-entrypoint.sh"]

# For mysql group replication
# ENTRYPOINT ["peer-finder"]
