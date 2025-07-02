# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

#FROM ghcr.io/actions/actions-runner:latest
FROM docker.io/ubuntu:22.04
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    apt-get install --yes --quiet=2 \
    curl \
    j2cli

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
