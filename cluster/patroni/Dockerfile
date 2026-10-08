FROM pgha/postgres:17
COPY patroni.yml.tmpl /etc/patroni/patroni.yml.tmpl
COPY entrypoint.sh post-bootstrap.sh pgbackrest-bootstrap.sh /usr/local/bin/
USER postgres
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
