FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV JDK_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:/root/.cargo/bin:/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${LD_LIBRARY_PATH}"
ENV LIBRARY_PATH="${JAVA_HOME}/lib/server:${LIBRARY_PATH}"
ENV CPATH="${JAVA_HOME}/include:${JAVA_HOME}/include/linux:${CPATH}"
ENV C_INCLUDE_PATH="${JAVA_HOME}/include:${JAVA_HOME}/include/linux:${C_INCLUDE_PATH}"

RUN apt-get update && apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    unzip \
    git \
    wget \
    pkg-config \
    libssl-dev \
    cmake \
    openjdk-11-jdk \
    openjdk-17-jdk \
    openjdk-17-jdk-headless \
    maven \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install newer protoc. Ubuntu 22.04's protobuf-compiler is too old.
ARG PROTOC_VERSION=25.3
RUN curl -L -o /tmp/protoc.zip \
    https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip \
    && unzip /tmp/protoc.zip -d /usr/local \
    && rm /tmp/protoc.zip \
    && protoc --version

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y

RUN java -version && \
    javac -version && \
    echo "JAVA_HOME=${JAVA_HOME}" && \
    find /usr/lib/jvm -name "jni.h" -print && \
    find /usr/lib/jvm -name "libjvm.so" -print && \
    protoc --version

WORKDIR /workspace

COPY build-comet.sh /usr/local/bin/build-comet.sh
RUN chmod +x /usr/local/bin/build-comet.sh

CMD ["/usr/local/bin/build-comet.sh"]
