FROM caddy:2.11.4-builder AS builder

RUN xcaddy build \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2 \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http \
    --with github.com/greenpau/caddy-security \
    --with github.com/mholt/caddy-ratelimit

FROM caddy:2.11.4-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

CMD ["docker-proxy"]
