FROM perl:5.40-slim-bookworm AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential libpq-dev libssl-dev zlib1g-dev ca-certificates \
        postgresql-client git bash \
    && rm -rf /var/lib/apt/lists/* \
    && cpanm --notest Carton \
    && rm -rf /root/.cpanm

ENV PERL_CARTON_PATH=/opt/perl-local \
    PERL5LIB=/opt/perl-local/lib/perl5 \
    PATH=/opt/perl-local/bin:$PATH \
    MOJO_HOME=/app

RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid app --create-home --shell /bin/bash app \
    && mkdir -p /app /opt/perl-local \
    && chown -R app:app /app /opt/perl-local

WORKDIR /app
USER app

COPY --chown=app:app cpanfile cpanfile.snapshot* ./

# Development image: includes test and develop dependencies; code is mounted as a volume.
FROM base AS dev
RUN carton install

# Production image: immutable, no develop dependencies.
FROM base AS production
RUN carton install --deployment --without develop
COPY --chown=app:app bin ./bin
COPY --chown=app:app config ./config
COPY --chown=app:app lib ./lib
COPY --chown=app:app migrations ./migrations
COPY --chown=app:app public ./public
COPY --chown=app:app templates ./templates
RUN mkdir -p var/input var/output var/logs
ENV MOJO_MODE=production
EXPOSE 3000
CMD ["perl", "bin/app", "daemon", "-l", "http://*:3000"]
