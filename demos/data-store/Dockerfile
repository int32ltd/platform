# Static web server for the demo pages: the demos landing page and every
# demo's HTML, served at https://catalog-data-store.dev.test on the local
# environment (`./demo.sh pages`).
#
# Build context is demos/ (see image.context in .localenv.yaml), so the pages
# keep their relative links: the landing page at /, this demo at /data-store/.
FROM docker.io/nginx:1.30.6-trixie

COPY index.html                            /usr/share/nginx/html/index.html
COPY platform-abstraction/index.html       /usr/share/nginx/html/platform-abstraction/index.html
COPY service-catalog-ownership/index.html  /usr/share/nginx/html/service-catalog-ownership/index.html
COPY data-store/index.html                 /usr/share/nginx/html/data-store/index.html
COPY data-store/flows.html                 /usr/share/nginx/html/data-store/flows.html
