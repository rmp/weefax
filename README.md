# mode7: a teletext carousel

`weefax.pl` loops through a folder of page files and transmits one page per
tick over a WebSocket. `<mode7-screen>` is a web component that receives the
stream, rolls the header as pages go past, and shows the page you asked for
when it comes round.

## Run

    cpanm Mojolicious
    npm install && npm run build
    ./weefax.pl daemon -l 'http://*:3000'

Or in Docker, with the page folder mounted at `/pages`:

    docker build -t mode7 .
    docker run -p 3000:3000 -v "$PWD/pages:/pages:ro" mode7

Open http://localhost:3000. For the authentic font, put `bedstead.otf` in
`public/fonts/` (see the note there).

| Variable             | Default    | Meaning                         |
|----------------------|------------|---------------------------------|
| `MODE7_PAGES`        | `./pages`  | Page folder                     |
| `MODE7_INTERVAL`     | `150`      | Milliseconds per page           |
| `MODE7_SUBPAGE_SECS` | `12`       | Default screen delay, seconds   |
| `MODE7_SERVICE`      | `WEEFAX 1` | 8-character header name         |

The folder is rescanned at the start of every cycle, so edits go out on the
next pass without a restart.

## Page folder

A file whose name starts with a page number (`100`–`8FF`, hex allowed) is
that page. A folder whose name starts with a page number makes every file
inside it a screen of that page, in natural sort order. Other folders are
just for organisation.

    pages/
      100 index.txt
      news/101 headlines.txt
      news/102.tti
      news/103 rotating.txt  three screens in one file
      weather/400@8/1.txt    screen 1 of 400, shown for 8 s
      weather/400@8/2.txt    screen 2 of 400

Row 0 is always the server's rolling header; screens fill rows 1–24.

### Rotating screens

A page with several screens shows each in turn, as broadcast carousels did.
Each screen has a delay: seconds (`8`, `8s`) or passes of the whole carousel
(`3c`). The most specific setting wins:

1. A directive inside the file (`@delay`, `@screen N`, or `CT` in .tti).
2. `@N` in the file name, e.g. `400@8/2@20.txt` holds that screen for 20 s.
3. `@N` in the nearest folder name, e.g. `400@8/`.
4. `MODE7_SUBPAGE_SECS`.

Each page keeps its own rotation, running whether or not anyone is watching.
A screen changes only when its page is transmitted, so the delay you see is
rounded up to the next pass, just as on air. Screens can come from several
files in a page folder, several screens in one file, or both.

### File formats

**.txt**: one or more screens of up to 24 lines, one per row, each up to
40 cells. Lines starting with these directives are not displayed:

    @delay N      delay for this screen and those after it in the file
    @screen [N]   start the next screen; N overrides the delay for it alone

Spacing attributes are written in braces and take one cell each:

    {red} {green} {yellow} {blue} {magenta} {cyan} {white} {black}
    {gred} … {gwhite} {gblack}         mosaic (graphics) colours
    {flash} {steady} {double} {normal} {dblwidth} {dblsize}
    {conceal} {contig} {sep} {blackbg} {newbg} {hold} {release}
    {startbox} {endbox} {x1F}          any byte in hex;  {{ for a literal {

Unicode sextant characters (U+1FB00–1FB3B, plus ▌ ▐ █) become the matching
mosaic codes, so you can draw graphics in a text editor after a `{gxxx}`
code. `£` maps to `#`, as in the UK G0 character set.

A screen that contains an `https://edit.tf/#0:…` URL is decoded from it, so
you can draw in edit.tf and paste one link per `@screen`.

**.tti / .ttix**: MRG teletext files (`OL,<row>,<text>`, with ESC or
high-bit control codes). Each `PN` line starts another screen, and
`CT,<n>,T` (seconds) or `CT,<n>,C` (cycles) sets its delay.

## Daily news

`weefax-news.pl` turns free RSS and Atom feeds into pages under
`pages/daily/`: a contents page, and for each section an index page plus up
to nine stories, each a headline and summary that rotates over several
screens when long. `news.conf` lists the sections, their page numbers and
feeds; stories from several feeds are interleaved and deduplicated.

    make up      # server on :8080, news refreshed now and every 24 h
    make news    # one refresh now
    make test    # unit and author tests, in Docker

A feed that fails is retried; a section whose feeds all fail keeps its
previous pages; a run where everything fails changes nothing. Pages are
built in a hidden folder and swapped in, so the carousel never shows a
half-written run. Link the contents page (120 by default) from page 100.

## Tests

`make test` builds the Docker `test` stage: it installs the develop
prerequisites listed in `Build.PL`, builds the distribution and runs
`prove -lr t xt` inside it. `t/` holds unit tests for `Weefax` and
`Weefax::News` and an HTTP/WebSocket test of `weefax.pl`; `xt/` runs
Perl::Critic (`.perlcriticrc`, severity 4), Test::Pod, Test::Pod::Coverage,
Test::Kwalitee, Test::CPAN::Changes and Test::MinimumVersion (5.020).
`prove -l t` runs the unit tests alone with a local Mojolicious.

`perl Build.PL && ./Build dist` builds a tarball (Module::Build).

## Component

    <script type="module" src="mode7-screen.js"></script>
    <mode7-screen page="100"></mode7-screen>

| Attribute | Meaning                                                |
|-----------|--------------------------------------------------------|
| `page`    | Page to wait for, e.g. `101`                           |
| `subpage` | Hold one screen (1-based) instead of following the rotation |
| `src`     | WebSocket URL (default `ws(s)://<this host>/ws`)       |
| `height`  | Height in px (default: fit the element's width)        |
| `font`    | CSS font family (default `Bedstead, monospace`)        |

Focused, it behaves like a remote: three digits select a page, Up/Down step
through the index, R reveals concealed text, M toggles mix mode. Methods
`reveal()` and `mix()` do the same from script; `.page` gets or sets the
target; `.pages` is the server's current index.

Events: `mode7-status` (`searching`, `found`, `offline`) and `mode7-page`
(`{page, subpage, subpages}`) each time a new page or subpage appears.

The renderer (`@techandsoftware/teletext` 1.3.1, bundled by `npm run build`) attaches its
SVG via a document-level selector, so the element must sit in the main
document rather than inside another component's shadow root. On Safari and
iOS its SVG mosaics can render badly; the library's `classic__font-for-mosaic`
view is the workaround.

## Protocol

Server to client, one JSON message per tick:

    {"t":"index","pages":["100","101",...]}          on connect and on change
    {"t":"pkt","p":"101","h":"WEEFAX 1 101 ..."}      header only
    {"t":"pkt","p":"101","h":"...","s":1,"n":2,"rows":[24 strings]}

`rows` (and `s`, `n`) are sent only to clients that selected that page:

    {"t":"select","pages":["101"]}

Strings carry raw teletext bytes (0x00–0x7F), control codes included.
