FROM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY src src
RUN npm run build

FROM alpine:3.22
RUN apk add --no-cache perl-mojolicious
WORKDIR /app
COPY mode7d.pl .
COPY public public
COPY --from=build /src/public/mode7-screen.js public/
ENV MODE7_PAGES=/pages MOJO_MODE=production
VOLUME /pages
EXPOSE 3000
USER nobody
CMD ["perl", "mode7d.pl", "daemon", "-l", "http://*:3000"]
