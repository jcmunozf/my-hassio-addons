FROM ghcr.io/home-assistant/base:latest

LABEL maintainer="Lucas DRAGO <lucas_drago@hotmail.fr>"

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
    sudo

COPY hostapd.conf /
COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
