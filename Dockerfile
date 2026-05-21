FROM mongo:5.0

LABEL maintainer="weiyeli@autox.ai"

USER root

### timezone  ###
ENV TZ=Asia/Shanghai \
    DEBIAN_FRONTEND=noninteractive

RUN apt update \
    && apt install -y tzdata \
    && ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && dpkg-reconfigure --frontend noninteractive tzdata \
    && rm -rf /var/lib/apt/lists/*


### setup environment ###
RUN sed -i s@/archive.ubuntu.com/@/mirrors.aliyun.com/@g /etc/apt/sources.list && \
    sed -i s@/security.ubuntu.com/@/mirrors.aliyun.com/@g /etc/apt/sources.list && \
    apt-get clean && \
    apt-get update && \
    apt-get install unzip wget -y

### setup dart sdk ###
ENV DART_HOME /opt/dart-sdk

# x86_64 服务器部署时改为: dartsdk-linux-x64-release.zip
# Apple Silicon 本地测试: dartsdk-linux-arm64-release.zip
ENV DART_SDK_ZIP_URL https://storage.flutter-io.cn/dart-archive/channels/stable/release/2.17.1/sdk/dartsdk-linux-arm64-release.zip

RUN mkdir -p $DART_HOME && \
    wget -O /tmp/dart-sdk.zip -t 5 "${DART_SDK_ZIP_URL}" && \
    unzip -q /tmp/dart-sdk.zip -d /opt &&\
    rm /tmp/dart-sdk.zip

### setup unpub from source ###
COPY ./unpub /src/unpub

ENV PATH ${PATH}:${DART_HOME}/bin:/.pub-cache/bin

RUN dart --version

### setup unpub ###
COPY docker-entrypoint.sh /usr/local/bin/
RUN ln -s usr/local/bin/docker-entrypoint.sh /entrypoint.sh # backwards compat

ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 4000
