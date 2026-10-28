# Stage 1: Use an image with bash and coreutils installed for the entrypoint script
FROM alpine:3.24
RUN apk add --no-cache bash coreutils

# Pinned to the commit build byte-identical to the binary in use. Upstream's
# 0.5 release line is an OLDER binary, so no release tag matches what runs.
COPY --from=stackdoubleflow/mchprs:sha-d492e43 /mchprs /mchprs

# Use entrypoint to inject secrets at runtime for "better" security
COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /data

RUN mkdir -p /etc/mchprs

COPY Config.toml /etc/mchprs/Config.toml

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
