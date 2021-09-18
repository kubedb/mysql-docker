FROM {BASE_IMAGE}

# https://www.reddit.com/r/mysql/comments/9ji4dk/mysql_chewing_up_and_not_releasing_memory/
# https://github.blog/2013-02-21-tcmalloc-and-mysql/
RUN set -x \
  && apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates google-perftools \
  && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man /tmp/*

# https://packages.ubuntu.com/bionic/amd64/libgoogle-perftools4/filelist
ENV LD_PRELOAD /usr/lib/x86_64-linux-gnu/libtcmalloc.so.4
