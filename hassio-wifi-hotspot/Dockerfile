FROM ghcr.io/home-assistant/base:latest

LABEL maintainer="jcmunozf"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV LANG=C.UTF-8

RUN apk add --no-cache \
    bash \
    jq \
    iw \
    hostapd \
    dnsmasq \
    networkmanager \
    net-tools \
    sudo \
    iproute2

COPY hostapd.conf /
COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
