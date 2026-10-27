# Pinned:
#   - base image by digest (Ubuntu 24.04 "noble")
#   - apt packages via a dated Ubuntu snapshot (gcc-13 = 13.3.0)
#   - Ghidra 12.1.3 and RetDec v5.0 by release URL + SHA-256
#   - Python packages via requirements.txt (exact versions)
FROM ubuntu@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

ARG UBUNTU_SNAPSHOT=20261020T000000Z
ARG GHIDRA_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.3_build/ghidra_12.1.3_PUBLIC_20260817.zip
ARG GHIDRA_SHA256=93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54
ARG RETDEC_URL=https://github.com/avast/retdec/releases/download/v5.0/RetDec-v5.0-Linux-Release.tar.xz
ARG RETDEC_SHA256=e5a7dd82987ff52b8c714892277d0b1d0190ab778c03036d01eb69c7658ab1a5

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    SOURCE_DATE_EPOCH=1790000000

# ca-certificates first so the snapshot mirror (HTTPS) can be used for everything else.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates \
 && if apt-get update -qq --error-on=any --snapshot ${UBUNTU_SNAPSHOT}; then SNAP="--snapshot ${UBUNTU_SNAPSHOT}"; \
    else echo "snapshot.ubuntu.com unavailable, using the regular Ubuntu archive"; apt-get update -qq; SNAP=""; fi \
 && apt-get install -y -qq --no-install-recommends $SNAP \
      gcc-13 g++-13 make cmake \
      git curl unzip xz-utils file binutils \
      python3 python3-venv \
      openjdk-21-jdk-headless \
 && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100 \
 && update-alternatives --install /usr/bin/cc  cc  /usr/bin/gcc-13 100 \
 && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100 \
 && update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-13 100 \
 && rm -rf /var/lib/apt/lists/*

# Fail the image build if the compiler is not exactly the one in our D1 plan.
RUN test "$(gcc -dumpfullversion)" = "13.3.0" || { echo "expected gcc 13.3.0, got $(gcc -dumpfullversion)"; exit 1; }

RUN curl -fsSL -o /tmp/ghidra.zip "${GHIDRA_URL}" \
 && echo "${GHIDRA_SHA256}  /tmp/ghidra.zip" | sha256sum -c - \
 && unzip -q /tmp/ghidra.zip -d /opt \
 && mv /opt/ghidra_12.1.3_PUBLIC /opt/ghidra \
 && rm /tmp/ghidra.zip
ENV GHIDRA_HOME=/opt/ghidra

RUN curl -fsSL -o /tmp/retdec.tar.xz "${RETDEC_URL}" \
 && echo "${RETDEC_SHA256}  /tmp/retdec.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/retdec && tar xJf /tmp/retdec.tar.xz -C /opt/retdec \
 && rm /tmp/retdec.tar.xz
ENV RETDEC_HOME=/opt/retdec

COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install -q --no-cache-dir -r /tmp/requirements.txt
ENV PATH=/opt/venv/bin:$PATH

WORKDIR /bakeoff
COPY . /bakeoff
CMD ["./run_all.sh"]
