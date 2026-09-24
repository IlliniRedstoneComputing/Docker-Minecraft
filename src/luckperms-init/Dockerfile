FROM python:3.12-alpine

# Unbuffered on purpose: this runs as a compose one-shot, and with the default
# block buffering `docker compose logs luckperms-init` shows nothing at all for
# the up-to-two-minute wait_for_api poll, so an operator cannot tell waiting
# from hung. It also keeps progress output if the container is killed mid-run,
# which is the only record of how far a partial application got.
ENV PYTHONUNBUFFERED=1

# PyYAML is pinned exactly; the base image deliberately is not, so rebuilds keep
# picking up CPython 3.12 patch releases and Alpine security updates. The only
# dependency is a pure-data parser, so the exposure of a floating base is small
# and the exposure of a stale one is not.
RUN pip install --no-cache-dir "PyYAML==6.0.2"

COPY seed.py /seed.py

ENTRYPOINT ["python3", "/seed.py"]
