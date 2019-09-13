FROM mysql:5.7.25

COPY on-start.sh /
COPY peer-finder /usr/local/bin/

# For standalone mysql
# default entrypoint of parent mysql:5.7.25
# ENTRYPOINT ["docker-entrypoint.sh"]

# For mysql group replication
# ENTRYPOINT ["peer-finder"]
