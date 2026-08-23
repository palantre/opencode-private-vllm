FROM ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:45047ae940975851c3b195997c91f6bb4add4b941880d94287e5f21ff5a6369a

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server tini \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && rm -f /etc/ssh/ssh_host_* \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin prohibit-password' \
        'X11Forwarding no' \
        'AllowTcpForwarding yes' \
        > /etc/ssh/sshd_config.d/99-opencode-gpu.conf

COPY start.sh /opt/opencode-gpu/start.sh
RUN chmod 755 /opt/opencode-gpu/start.sh

EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/opt/opencode-gpu/start.sh"]
