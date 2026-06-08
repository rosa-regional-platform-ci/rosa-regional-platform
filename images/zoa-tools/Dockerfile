FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

ARG OC_VERSION="stable-4.21"
ARG AWS_CLI_VERSION="2.34.63"
ARG YQ_VERSION="v4.53.3"

LABEL name="zoa-tools" \
      summary="ZOA Trusted Actions execution image" \
      description="FIPS-compliant toolbox for executing Zero Operator Access Trusted Actions" \
      io.k8s.display-name="ZOA Tools"

RUN microdnf install -y \
        bash \
        jq \
        python3 \
        tar \
        gzip \
        unzip \
        openssl \
        shadow-utils \
    && microdnf clean all \
    && rm -rf /var/cache/yum /var/cache/dnf /var/log/dnf* /var/log/yum* /tmp/*

# FIPS crypto policy
RUN update-crypto-policies --set FIPS 2>/dev/null || true

# kubectl + oc (Red Hat FIPS-compliant BoringCrypto build)
RUN curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
        -o /tmp/oc.tar.gz && \
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl && \
    rm -f /tmp/oc.tar.gz

# AWS CLI v2 (FIPS endpoints enabled at runtime via AWS_USE_FIPS_ENDPOINT=true)
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
        -o /tmp/awscliv2.zip && \
    unzip -qo /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws && \
    find /usr/local/aws-cli -name "examples" -type d -exec rm -rf {} + 2>/dev/null; true

# yq
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Non-root user (OpenShift-compatible: uid 1001, gid 0)
RUN useradd -r -u 1001 -g 0 -d /home/zoa -s /bin/bash zoa && \
    mkdir -p /home/zoa /artifacts /zoa && \
    chown -R 1001:0 /home/zoa /artifacts /zoa && \
    chmod -R g=u /home/zoa /artifacts /zoa

USER 1001
WORKDIR /home/zoa

RUN kubectl version --client && \
    oc version --client && \
    aws --version && \
    jq --version && \
    yq --version && \
    python3 --version
