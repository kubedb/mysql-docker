FROM mysql:8.0.21

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends strace psmisc

COPY on-start.sh /
COPY peer-finder /usr/local/bin/peer-finder

#VOLUME /etc/mysql

# For standalone mysql
# default entrypoint of parent mysql:8.0.21
# ENTRYPOINT ["docker-entrypoint.sh"]

# For mysql group replication
# ENTRYPOINT ["peer-finder"]

COPY docker-entrypoint.sh /usr/local/bin/
RUN set -x; \
  rm -rf /entrypoint.sh; \
  ln -s /usr/local/bin/docker-entrypoint.sh /entrypoint.sh # backwards compat
