# pgbackrest_exporter on top of OUR postgres image, so `pgbackrest info` runs
# the same pgBackRest version that wrote the repository. The upstream image
# (woblerr/pgbackrest_exporter) is used only as the source of the static
# binary: its entrypoint chowns /var/lib/pgbackrest when run as root, and
# it ships an older pgBackRest.
ARG EXPORTER_IMAGE=woblerr/pgbackrest_exporter:v0.21.0
FROM ${EXPORTER_IMAGE} AS exporter

FROM pgha/postgres:17
COPY --from=exporter /etc/pgbackrest/pgbackrest_exporter /usr/local/bin/pgbackrest_exporter
USER postgres
EXPOSE 9854
ENTRYPOINT ["/usr/local/bin/pgbackrest_exporter"]
