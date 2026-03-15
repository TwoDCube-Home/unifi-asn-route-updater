FROM registry.access.redhat.com/ubi9/ubi AS build

RUN set -x \
    && dnf install -y --nodocs \
        python3-pip \
        python3-devel \
        gcc \
    && pip3 install --prefix=/opt/aggregate6 aggregate6 \
    && dnf clean all

FROM registry.access.redhat.com/ubi9/ubi-minimal AS final

RUN set -x \
    && microdnf install -y --nodocs \
        jq \
        python3 \
    && microdnf clean all

COPY --from=build /opt/aggregate6 /usr
COPY --chmod=755 ui-update-asn-routes.sh /usr/local/bin/ui-update-asn-routes

USER nobody

WORKDIR /home
ENTRYPOINT ["ui-update-asn-routes"]
CMD []
