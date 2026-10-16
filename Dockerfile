FROM python:3.11-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SOURCE_DATE_EPOCH=315532800

WORKDIR /build

RUN pip install --no-compile "poetry>=2.1,<3" poetry-plugin-export

COPY pyproject.toml poetry.lock README.md ./
COPY src ./src

RUN mkdir -p dist \
 && poetry export --without-hashes --format constraints.txt --output dist/constraints.txt \
 && pip wheel --isolated --requirement dist/constraints.txt --wheel-dir dist/vendor \
 && poetry build --format wheel

FROM python:3.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

COPY --from=builder /build/dist /tmp/dist

RUN pip install --no-index --no-deps --no-compile /tmp/dist/vendor/*.whl /tmp/dist/*.whl \
 && rm -rf /tmp/dist

RUN echo 'app:x:10001:' >> /etc/group \
 && echo 'app:x:10001:10001:audit-svc:/nonexistent:/usr/sbin/nologin' >> /etc/passwd

USER 10001:10001

EXPOSE 8080

CMD ["server"]
