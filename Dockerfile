FROM ubuntu:18.04

RUN sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        dnsutils \
        libxml2 \
        systemd-sysv \
        tcpdump \
        dante-server && \
    rm -rf /var/lib/apt/lists/*

COPY MotionPro_Linux_Ubuntu_x64_build-8383-34.sh /tmp/MotionPro_Linux_Ubuntu_x64_build-8383-34.sh

RUN chmod +x /tmp/MotionPro_Linux_Ubuntu_x64_build-8383-34.sh && \
    /tmp/MotionPro_Linux_Ubuntu_x64_build-8383-34.sh && \
    rm -f /tmp/MotionPro_Linux_Ubuntu_x64_build-8383-34.sh

RUN useradd -r -s /sbin/nologin dante

COPY danted.conf /etc/danted.conf

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

HEALTHCHECK --interval=2s --timeout=1s --start-period=2s --retries=3 \
    CMD test "$(MotionPro -a)" = "VPN Status: connected" || exit 1

CMD ["bash"]
