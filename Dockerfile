FROM docker.io/library/ubuntu:rolling
ENV DEBIAN_FRONTEND noninteractive
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
