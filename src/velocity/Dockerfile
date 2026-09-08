FROM itzg/mc-proxy:java25

ENV TYPE=VELOCITY

WORKDIR /usr/src/init_data
COPY ./server .
# Set permissions for the server files (user's name is 
# bungeecord in the base image despite using Velocity)
RUN chown -R bungeecord:bungeecord . && \ 
    find . -type d -exec chmod 755 {} + && \
    find . -type f -exec chmod 644 {} +

WORKDIR /

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]

WORKDIR /server