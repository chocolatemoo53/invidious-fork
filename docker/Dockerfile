FROM --platform=linux/amd64 git.nadeko.net/fijxu/84codes-crystal-openssl:1.21.0 AS dependabot-crystal

# OpenSSL memory leak fix already compiled into base image
# Reference: https://github.com/iv-org/invidious/issues/1438#issuecomment-3087636228

FROM dependabot-crystal AS builder

RUN apk add --no-cache sqlite-static yaml-static

ARG release
ARG gcry

WORKDIR /invidious

COPY ./shard.yml ./shard.yml
COPY ./shard.lock ./shard.lock

RUN shards install --production

COPY ./src/ ./src/
COPY ./.git/ ./.git/

# Required for fetching player dependencies
COPY ./scripts/ ./scripts/
COPY ./assets/ ./assets/
COPY ./videojs-dependencies.yml ./videojs-dependencies.yml

RUN crystal spec --warnings all \
    --link-flags "-lxml2 -llzma"

RUN --mount=type=cache,target=/root/.cache/crystal \
    if [ "${gcry}" = "1" ]; then GCRY_FLAG="-Dgc_none"; else GCRY_FLAG=""; fi && \
    if [ "${release}" = "1" ] ; then \
        crystal build ./src/invidious.cr \
        --release -s -p -t --mcpu=x86-64-v2 \
        --static --warnings all \
        --link-flags "-lxml2 -llzma -no-pie" ${GCRY_FLAG}; \
    else \
        crystal build ./src/invidious.cr \
        --static --warnings all \
        --link-flags "-lxml2 -llzma -no-pie" ${GCRY_FLAG}; \
    fi

FROM mirror.gcr.io/alpine:3.24
RUN apk add --no-cache rsvg-convert ttf-opensans tini tzdata
WORKDIR /invidious
RUN addgroup -g 1000 -S invidious && \
    adduser -u 1000 -S invidious -G invidious
COPY --chown=invidious ./config/config.* ./config/
RUN mv -n config/config.example.yml config/config.yml
RUN sed -i 's/host: \(127.0.0.1\|localhost\)/host: invidious-db/' config/config.yml
COPY ./config/sql/ ./config/sql/
COPY ./locales/ ./locales/
COPY --from=builder /invidious/assets ./assets/
COPY --from=builder /invidious/invidious .
RUN chmod o+rX -R ./assets ./config ./locales

EXPOSE 3000
USER invidious
ENTRYPOINT ["/sbin/tini", "--"]
CMD [ "/invidious/invidious" ]
