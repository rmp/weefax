FROM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY src src
RUN npm run build

FROM alpine:3.22 AS base
RUN apk add --no-cache perl-mojolicious perl-io-socket-ssl ca-certificates libjpeg-turbo-utils

FROM base AS test
RUN apk add --no-cache build-base perl-dev perl-app-cpanminus perl-module-build
WORKDIR /src
COPY Build.PL ./
COPY lib/Weefax.pm lib/
RUN cpanm -q -n --installdeps --with-develop .
COPY . .
COPY --from=build /src/public/mode7-screen.js public/
RUN perl Build.PL && ./Build manifest && ./Build distdir \
 && cd Weefax-[0-9]* && prove -lr t xt

FROM base
WORKDIR /app
COPY lib lib
COPY weefax.pl weefax-news.pl weefax-art.pl news.conf ./
COPY public public
COPY --from=build /src/public/mode7-screen.js public/
ENV MODE7_PAGES=/pages MOJO_MODE=production
VOLUME /pages
EXPOSE 3000
USER nobody
CMD ["perl", "weefax.pl", "daemon", "-l", "http://*:3000"]
