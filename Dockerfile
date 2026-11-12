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

FROM base AS dependency-lock
COPY --chown=app:app cpanfile cpanfile.snapshot* ./
RUN carton install

FROM base AS dev
COPY --chown=app:app cpanfile cpanfile.snapshot* ./
RUN carton install

FROM base AS production-dependencies
COPY --chown=app:app cpanfile ./
COPY --from=dependency-lock --chown=app:app /app/cpanfile.snapshot ./cpanfile.snapshot
RUN carton install --deployment --without develop,test

FROM perl:5.40-slim-bookworm AS production
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libpq5 \
    && rm -rf /var/lib/apt/lists/*

ENV PERL_CARTON_PATH=/opt/perl-local \
    PERL5LIB=/opt/perl-local/lib/perl5 \
    PATH=/opt/perl-local/bin:$PATH \
    MOJO_HOME=/app \
    MOJO_MODE=production

RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid app --create-home --shell /bin/bash app \
    && mkdir -p /app /opt/perl-local \
    && chown -R app:app /app /opt/perl-local

WORKDIR /app
USER app

COPY --from=production-dependencies --chown=app:app /opt/perl-local /opt/perl-local
COPY --chown=app:app bin ./bin
COPY --chown=app:app config ./config
COPY --chown=app:app lib ./lib
COPY --chown=app:app migrations ./migrations
COPY --chown=app:app public ./public
COPY --chown=app:app templates ./templates
COPY --from=dependency-lock --chown=app:app /app/cpanfile.snapshot ./cpanfile.snapshot
RUN mkdir -p var/input var/output var/logs \
    && perl -Ilib -c bin/app \
    && perl -Ilib -c bin/worker \
    && perl -Ilib -c bin/procedure \
    && perl -Ilib -MFile::Find -e 'find({no_chdir => 1, wanted => sub { return unless /\.pm\z/; system($^X, "-Ilib", "-c", $File::Find::name) == 0 or die "syntax check failed\n"; }}, "lib")'

EXPOSE 3000
CMD ["perl", "bin/app", "daemon", "-l", "http://*:3000"]
