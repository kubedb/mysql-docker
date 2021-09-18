FROM debian:buster

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

RUN set -x \
  && apt-get update \
  && apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl bzip2 build-essential automake autoconf libxslt-dev xsltproc docbook-xsl git

RUN set -x \
  && curl -fsSL -O https://github.com/jemalloc/jemalloc/releases/download/5.2.1/jemalloc-5.2.1.tar.bz2 \
  && tar xvfj jemalloc-5.2.1.tar.bz2 \
  && cd jemalloc-5.2.1 \
  && autoconf \
  && ./configure \
  && make dist \
  && make install



FROM {BASE_IMAGE}

# https://www.reddit.com/r/mysql/comments/9ji4dk/mysql_chewing_up_and_not_releasing_memory/
# https://github.blog/2013-02-21-tcmalloc-and-mysql/
# RUN set -x \
#   && apt-get update \
#   && apt-get install -y --no-install-recommends ca-certificates google-perftools \
#   && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man /tmp/*

# https://packages.ubuntu.com/bionic/amd64/libgoogle-perftools4/filelist
# ENV LD_PRELOAD /usr/lib/x86_64-linux-gnu/libtcmalloc.so.4

# https://gist.github.com/diginfo/be7347e6e6c4f05375c51bca90f220e8
COPY --from=0 /usr/local/lib/libjemalloc.so.2 /usr/local/lib/libjemalloc.so.2

ENV LD_PRELOAD /usr/local/lib/libjemalloc.so.2
