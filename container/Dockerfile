FROM vllm/vllm-openai:v0.27.1@sha256:c2f3b1b964e47809b722b5e75b61b1e7b39a50f70388cf2bf2418f16a9f31da2

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
