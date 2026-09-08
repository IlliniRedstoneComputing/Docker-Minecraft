# Stage 1: Use an image with bash and coreutils installed for the entrypoint script
FROM alpine:latest
RUN apk add --no-cache bash coreutils

COPY --from=stackdoubleflow/mchprs /mchprs /mchprs

# Use entrypoint to inject secrets at runtime for "better" security
COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /data

RUN mkdir -p /etc/mchprs

COPY Config.toml /etc/mchprs/Config.toml

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
