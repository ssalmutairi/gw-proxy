# No platform pin here: the image is published as a multi-arch manifest
# (linux/amd64 + linux/arm64) via `docker buildx build --platform ...`, so the
# base resolves to the right architecture for each target. nginx config and the
# shell entrypoint are arch-independent.
FROM nginx:1.27-alpine

LABEL org.opencontainers.image.title="gw-proxy" \
      org.opencontainers.image.version="1.2.0"

RUN apk add --no-cache bash

COPY templates/ /etc/nginx/templates-src/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && rm -f /etc/nginx/conf.d/default.conf \
 # Make the only paths nginx writes to owned by the non-root 'nginx' user (uid 101)
 # so the pod needs no mounted volumes and stays fully stateless/scalable:
 #   - /etc/nginx/conf.d : entrypoint renders default.conf here
 #   - /var/cache/nginx  : client/proxy temp files
 # The pid is moved to /tmp (world-writable) so non-root can write it.
 && chown -R 101:101 /etc/nginx/conf.d /var/cache/nginx \
 && sed -i 's|^pid .*nginx\.pid;|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf

# Listens on 8080 (non-root can't bind privileged ports); Service maps 80 -> 8080.
EXPOSE 8080
USER 101

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
