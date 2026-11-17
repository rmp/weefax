IMAGE ?= weefax
export PAGES_UID := $(shell id -u)
export PAGES_GID := $(shell id -g)

.PHONY: image run up down news art test
image:
	docker build -t $(IMAGE) .

run: image
	docker run --rm -p 8080:3000 -v "$(CURDIR)/pages:/pages:ro" $(IMAGE)

up: art news
	docker compose up -d --build

down:
	docker compose down

news: image
	docker run --rm --user $(PAGES_UID):$(PAGES_GID) -v "$(CURDIR)/pages:/pages" -v "$(CURDIR)/news.conf:/app/news.conf:ro" $(IMAGE) perl weefax-news.pl

art: image
	docker run --rm --user $(PAGES_UID):$(PAGES_GID) -v "$(CURDIR)/pages:/pages" $(IMAGE) perl weefax-art.pl --aspect 0.8-2.5

test:
	docker build --target test --progress plain .
